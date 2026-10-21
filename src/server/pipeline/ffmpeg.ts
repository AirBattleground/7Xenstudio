/** One ffmpeg process: WebM chunks in on stdin (with backpressure), H.264/AAC out through tee, progress → kbps/fps. */
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { ffmpegArgs, ProgressMeter, type Encoder, type TeeSlave } from "./encoder.js";
import { log, rateLimited } from "./log.js";

export interface FfmpegOpts {
  ffmpegPath: string;
  encoder: Encoder;
  fps: number;
  kbps: number;
  cores: number;
  slaves: TeeSlave[];
  /** a progress block arrived (bitrate / fps / out_time updated) */
  onProgress?: () => void;
  /** slave #index stopped (destination refused or dropped); the others keep going */
  onOutputFailed?: (index: number, error: string) => void;
  /** called once when the process ends for any reason */
  onExit: (reason: string) => void;
}

/** ffmpeg output line safe to log: stream keys after the RTMP app name are cut off. */
export const redactKeys = (line: string) => line.replace(/(rtmps?:\/\/[^/\s]+\/[^/\s?']+\/)[^\s'|\]:]+/g, "$1…");

/** "Slave muxer #1 failed: Connection refused, continuing with 1/2 slaves." → {index, error} */
export function parseSlaveFailure(line: string): { index: number; error: string } | null {
  const m = /Slave muxer #(\d+) failed(?::\s*(.*?))?(?:,\s*continuing with.*)?$/.exec(line);
  if (!m) return null;
  return { index: Number(m[1]), error: (m[2] ?? "").trim() || "failed" };
}

export interface FfmpegProcess {
  readonly alive: boolean;
  readonly meter: ProgressMeter;
  write(buf: Buffer): Promise<void>;
  stop(graceMs?: number): Promise<void>;
  kill(): void;
}

export class FfmpegPipe implements FfmpegProcess {
  private child: ChildProcessWithoutNullStreams;
  private exited = false;
  /** stop() was called — the demuxer's "File ended prematurely" is expected then */
  private stopping = false;
  private lastStderr = "";
  readonly meter = new ProgressMeter();
  bytesIn = 0;

  constructor(private readonly opts: FfmpegOpts) {
    const args = ffmpegArgs(opts.encoder, { fps: opts.fps, kbps: opts.kbps, cores: opts.cores, slaves: opts.slaves });
    log.debug("ffmpeg start", { args: redactKeys(args.join(" ")) });
    this.child = spawn(opts.ffmpegPath, args, { stdio: ["pipe", "pipe", "pipe"] });
    const warn = rateLimited(10, 30_000);
    this.child.stdout.setEncoding("utf8").on("data", (t: string) => {
      if (this.meter.feed(t)) opts.onProgress?.();
    });
    this.child.stderr.setEncoding("utf8").on("data", (t: string) => {
      for (const line of t.split("\n").map((l) => redactKeys(l.trim())).filter(Boolean)) {
        this.lastStderr = line;
        const failed = parseSlaveFailure(line);
        if (failed) opts.onOutputFailed?.(failed.index, failed.error);
        if (!this.stopping) warn((dropped) => log.warn(`ffmpeg: ${line}`, dropped ? { dropped } : undefined));
      }
    });
    // a broken pipe after ffmpeg died surfaces here — the exit handler reports it
    this.child.stdin.on("error", () => {});
    this.child.on("error", (err) => this.finish(`ffmpeg could not start (${err.message}). Install ffmpeg or set FFMPEG_PATH.`));
    this.child.on("close", (code, signal) =>
      this.finish(`The encoder (ffmpeg) stopped (${signal ?? `code ${code}`})${this.lastStderr ? `: ${this.lastStderr}` : ""}`),
    );
  }

  get alive() {
    return !this.exited;
  }

  get pid() {
    return this.child.pid;
  }

  private finish(reason: string) {
    if (this.exited) return;
    this.exited = true;
    this.opts.onExit(reason.slice(0, 300));
  }

  /** Write one chunk; resolves once ffmpeg can take more (so the page slows down instead of us buffering). */
  async write(buf: Buffer): Promise<void> {
    if (this.exited || this.stopping || this.child.stdin.destroyed) return;
    this.bytesIn += buf.length;
    if (this.child.stdin.write(buf)) return;
    await new Promise<void>((resolve) => {
      const done = () => {
        this.child.stdin.off("drain", done);
        this.child.off("close", done);
        resolve();
      };
      this.child.stdin.once("drain", done);
      this.child.once("close", done);
    });
  }

  /** End stdin (ffmpeg flushes and closes the outputs cleanly), SIGKILL after `graceMs`. */
  async stop(graceMs = 3000): Promise<void> {
    if (this.exited) return;
    this.stopping = true;
    const closed = new Promise<void>((r) => this.child.once("close", () => r()));
    this.child.stdin.end();
    const timer = setTimeout(() => this.child.kill("SIGKILL"), graceMs);
    await closed;
    clearTimeout(timer);
  }

  kill() {
    this.stopping = true;
    if (!this.exited) this.child.kill("SIGKILL");
  }
}
