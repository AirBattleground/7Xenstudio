/**
 * The renderer: headless Chrome on the render page → MediaRecorder WebM chunks → ffmpeg (H.264/AAC) → tee to every
 * target (fragmented-MP4 recording file, RTMP destinations, the local preview path).
 *
 * ffmpeg starts first (so it's ready for the WebM header), then Chrome. Both restart together (see runner.ts).
 */
import { mkdirSync, statSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { RenderStatus } from "../../shared/types.js";
import { ChromeMissingError, RenderBrowser } from "./browser.js";
import { defaultFfmpegPath, detectEncoder, type TeeSlave } from "./encoder.js";
import { FfmpegPipe } from "./ffmpeg.js";
import { log } from "./log.js";
import { FatalError, Supervisor, type Attempt, type AttemptHooks } from "./runner.js";
import { recordingFileName, type Pipeline, type PipelineOptions, type PipelineStatus, type PipelineTarget } from "./types.js";

export { detectEncoder, detectedEncoder } from "./encoder.js";
export type { Pipeline, PipelineOptions, PipelineStatus, PipelineTarget } from "./types.js";

/** How often onStatus fires while nothing else changes. */
const STATUS_EVERY_MS = 2000;
const TICK_MS = 500;
const AUDIO_KBPS = 160;

/** Bytes-written samples → kbps over the last `windowMs` (fragmented MP4 grows in steps, so average over a while). */
export class GrowthRate {
  private samples: { at: number; bytes: number }[] = [];
  constructor(
    private readonly windowMs = 10_000,
    private readonly now: () => number = Date.now,
  ) {}
  reset() {
    this.samples = [];
  }
  add(bytes: number) {
    const at = this.now();
    this.samples.push({ at, bytes });
    while (this.samples.length > 2 && at - this.samples[0]!.at > this.windowMs) this.samples.shift();
  }
  kbps(): number | null {
    const a = this.samples[0];
    const b = this.samples.at(-1);
    if (!a || !b || b.at - a.at < 3000 || b.bytes <= a.bytes) return null;
    return Math.round(((b.bytes - a.bytes) * 8) / (b.at - a.at));
  }
}

export interface PublishPlan {
  slaves: TeeSlave[];
  /** target id per slave, same order (tee reports failures by slave index) */
  ids: string[];
  /** absolute path of the recording file of this attempt (first record target), null when not recording */
  recordingPath: string | null;
}

/** Targets → tee slaves for one attempt. Record targets get a fresh file name (each (re)start writes a new file). */
export function publishPlan(o: Pick<PipelineOptions, "showId" | "slug" | "title" | "targets">, now = new Date()): PublishPlan {
  const slaves: TeeSlave[] = [];
  const ids: string[] = [];
  let recordingPath: string | null = null;
  const seen = new Set<string>();
  for (const t of o.targets) {
    let url = t.url;
    if (t.kind === "record") {
      url = path.join(t.url, recordingFileName(o.slug || slugify(o.title), o.showId, now));
      recordingPath ??= url;
    }
    if (seen.has(url)) continue;
    seen.add(url);
    slaves.push({ kind: t.kind, url });
    ids.push(t.id);
  }
  return { slaves, ids, recordingPath };
}

export const slugify = (title: string) =>
  title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 40) || "show";

class RendererPipeline implements Pipeline {
  private readonly sup: Supervisor;
  private encoder: string | null = null;
  private ffmpeg: FfmpegPipe | null = null;
  private browser: RenderBrowser | null = null;
  private recordingFile: string | null = null;
  private recordingPath: string | null = null;
  private readonly fileRate = new GrowthRate();
  private failed = new Map<string, string>();
  private pageError: string | null = null;
  private timer: NodeJS.Timeout;
  private lastEmit = 0;
  private stopped = false;
  private readonly ffmpegPath: string;

  constructor(private readonly o: PipelineOptions) {
    this.ffmpegPath = defaultFfmpegPath(o.ffmpegPath);
    this.sup = new Supervisor((hooks) => this.launch(hooks), {
      onChange: () => this.emit(),
      onFatal: (reason) => {
        if (this.stopped) return;
        this.stopped = true;
        clearInterval(this.timer);
        void this.sup.stop();
        this.o.onExit(reason);
      },
    });
    this.timer = setInterval(() => {
      this.sampleRecording();
      void this.sup.tick().then(() => {
        if (Date.now() - this.lastEmit >= STATUS_EVERY_MS) this.emit();
      });
    }, TICK_MS);
    log.info(`Starting the renderer for "${o.title}"`, { showId: o.showId, targets: o.targets.map((t) => t.name).join(", ") || "none" });
    void this.sup.start();
  }

  private async launch(hooks: AttemptHooks): Promise<Attempt> {
    if (!this.encoder) {
      try {
        this.encoder = await detectEncoder({ ffmpegPath: this.ffmpegPath, override: this.o.encoder });
        log.info(`Encoder: ${this.encoder}`);
      } catch (err) {
        throw new FatalError((err as Error).message);
      }
    }
    const plan = publishPlan(this.o);
    for (const t of this.o.targets) if (t.kind === "record") mkdirSync(t.url, { recursive: true });
    this.failed = new Map();
    this.pageError = null;
    this.recordingPath = plan.recordingPath;
    this.recordingFile = plan.recordingPath ? path.basename(plan.recordingPath) : null;
    this.fileRate.reset();
    if (plan.slaves.length === 0) log.warn("No outputs for this show: encoding only, sending it nowhere");

    const ff = new FfmpegPipe({
      ffmpegPath: this.ffmpegPath,
      encoder: this.encoder,
      fps: this.o.fps,
      kbps: this.o.videoKbps,
      cores: os.cpus().length,
      slaves: plan.slaves,
      onProgress: () => {
        hooks.progress();
        if (ff === this.ffmpeg) this.emit();
      },
      onOutputFailed: (index, error) => {
        const id = plan.ids[index];
        if (!id || ff !== this.ffmpeg) return;
        const name = this.o.targets.find((t) => t.id === id)?.name ?? `output ${index + 1}`;
        this.failed.set(id, plainOutputError(error));
        log.warn(`Stopped sending to ${name}: ${error}`);
        this.emit();
      },
      onExit: hooks.exit,
    });
    const browser = new RenderBrowser({
      url: this.o.renderUrl,
      chromePath: this.o.chromePath || process.env.CHROME_PATH || null,
      extraArgs: (process.env.CHROME_ARGS ?? "").split(/\s+/).filter(Boolean),
      onChunk: async (buf) => {
        await ff.write(buf);
        hooks.chunk();
      },
      onStatus: (s: RenderStatus) => {
        if (browser === this.browser) this.pageError = s.error;
      },
      onExit: hooks.exit,
    });
    this.ffmpeg = ff;
    this.browser = browser;
    const stop = async () => {
      await browser.stop();
      await ff.stop(3000);
    };
    try {
      await browser.start();
    } catch (err) {
      await stop();
      if (err instanceof ChromeMissingError) throw new FatalError(err.message);
      throw err;
    }
    return { flowing: () => ff.alive && ff.meter.advancing, stop };
  }

  status(): PipelineStatus {
    const st = this.sup.state === "stopped" ? "error" : this.sup.state;
    const live = this.sup.state === "live";
    const m = live && this.ffmpeg?.alive ? this.ffmpeg.meter : null;
    return {
      state: st,
      fps: m?.fps ?? null,
      encoder: this.encoder,
      // through tee ffmpeg reports total_size=N/A: use the recording's growth, else the CBR target
      bitrateKbps: m ? (m.kbps ?? this.fileRate.kbps() ?? this.o.videoKbps + AUDIO_KBPS) : null,
      error: this.sup.error ?? (live ? this.pageError : null),
      outputs: this.o.targets.map((t) => {
        const failed = this.failed.get(t.id);
        if (failed) return { id: t.id, ok: false, error: failed };
        if (live) return { id: t.id, ok: true, error: null };
        return { id: t.id, ok: false, error: st === "error" ? "Not sending while the renderer restarts" : null };
      }),
      recordingFile: st !== "error" ? this.recordingFile : null,
      restarts: this.sup.restarts,
    };
  }

  private sampleRecording() {
    if (!this.recordingPath) return;
    try {
      this.fileRate.add(statSync(this.recordingPath).size);
    } catch {
      /* not created yet */
    }
  }

  private emit() {
    if (this.stopped) return;
    this.lastEmit = Date.now();
    try {
      this.o.onStatus(this.status());
    } catch (err) {
      log.warn("onStatus threw", { err });
    }
  }

  async stop(): Promise<void> {
    this.stopped = true;
    clearInterval(this.timer);
    const done = this.sup.stop();
    // also stop an attempt that is still launching (the supervisor only sees it once launch returns)
    await Promise.all([this.browser?.stop(), this.ffmpeg?.stop(3000)]);
    await done;
    log.info("Renderer stopped", { showId: this.o.showId });
  }
}

/** ffmpeg's error for a failed slave → a short plain-English line for the status bar. */
export function plainOutputError(error: string): string {
  if (/refused/i.test(error)) return "The destination refused the connection";
  if (/broken pipe|reset by peer|end of file|I\/O error/i.test(error)) return "The destination dropped the connection";
  if (/no such file|permission denied|no space/i.test(error)) return `Cannot write the recording (${error})`;
  if (/timed out/i.test(error)) return "The destination did not answer";
  return `Stopped sending (${error})`;
}

/** Start the renderer for one show. Returns at once; progress arrives through onStatus. */
export function startPipeline(opts: PipelineOptions): Pipeline {
  return new RendererPipeline(opts);
}
