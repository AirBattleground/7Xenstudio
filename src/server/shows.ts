/**
 * Shows: CRUD, the live switching state (control + long-poll), and going live: one show at a time, the renderer
 * pipeline with its targets (recording, stream keys, the local preview, integration targets) and the integration's
 * broadcast heartbeat.
 */
import {
  DEFAULT_FPS,
  DEFAULT_OVERLAYS,
  DEFAULT_VIDEO_KBPS,
  type Control,
  type ControlState,
  type Show,
  type ShowConfig,
  type ShowStatus,
  type UpdateShowInput,
} from "../shared/types.js";
import { HttpError, conflict, notFound } from "./http.js";
import type { IntegrationRegistry } from "./integrations/registry.js";
import type { Pipeline, PipelineOptions, PipelineStatus, PipelineTarget, StartPipeline } from "./pipeline/types.js";
import { newId, type Store } from "./store.js";

export const LONG_POLL_MS = 25_000;
export const INTEGRATION_HEARTBEAT_MS = 10_000;

export const slugify = (s: string) =>
  s
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40) || "show";

/** rtmp://host/app + key → rtmp://host/app/key (tolerates a trailing slash on the URL) */
export const joinStreamKey = (url: string, key: string) => `${url.trim().replace(/\/+$/, "")}/${key.trim().replace(/^\/+/, "")}`;

export function defaultConfig(firstDeviceId: string | null): ShowConfig {
  return {
    v: 1,
    scenes: [
      { id: "starting", name: "Starting soon", layout: "full", slots: [{ kind: "slate" }] },
      { id: "phone", name: "Phone", layout: "full", slots: [firstDeviceId ? { kind: "device", id: firstDeviceId } : null] },
      { id: "host", name: "Host", layout: "full", slots: [{ kind: "camera" }] },
      { id: "break", name: "Break", layout: "full", slots: [{ kind: "slate" }] },
    ],
    overlays: structuredClone(DEFAULT_OVERLAYS),
    transition: "fade",
    introPropId: null,
  };
}

interface Runtime {
  pipeline: Pipeline | null;
  targets: PipelineTarget[];
  last: PipelineStatus | null;
  /** the renderer gave up / failed to start (kept after the show ended so the status says why) */
  error: string | null;
  integration: { id: string; name: string; broadcastId: string | null; watchUrl: string | null; error: string | null } | null;
  heartbeat: NodeJS.Timeout | null;
  stopping: boolean;
}

export interface ShowsDeps {
  store: Store;
  integrations: IntegrationRegistry;
  startPipeline: StartPipeline;
  /** the pipeline's settings (render URL needs the port + render token) */
  renderUrl: (showId: string) => string;
  previewUrl: (showId: string) => string;
  ffmpegPath: string | null;
  chromePath: string | null;
  encoder: string | null;
  log?: (msg: string) => void;
  now?: () => number;
}

export class Shows {
  private controls = new Map<string, Control>();
  private waiters = new Map<string, Set<() => void>>();
  private runtimes = new Map<string, Runtime>();
  /** last encoder the pipeline reported (StudioInfo.encoder) */
  lastEncoder: string | null = null;
  private readonly now: () => number;
  private readonly log: (msg: string) => void;

  constructor(private readonly d: ShowsDeps) {
    this.now = d.now ?? Date.now;
    this.log = d.log ?? (() => {});
    // the pipeline doesn't survive a restart: nothing is live after boot
    let changed = false;
    for (const s of d.store.doc.shows) {
      if (s.state === "LIVE") {
        s.state = "IDLE";
        s.liveSince = null;
        changed = true;
      }
    }
    if (changed) d.store.save();
  }

  private iso() {
    return new Date(this.now()).toISOString();
  }

  // ---------------------------------------------------------------- CRUD

  list(): Show[] {
    return [...this.d.store.doc.shows].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  }

  get(id: string): Show {
    const s = this.d.store.doc.shows.find((x) => x.id === id);
    if (!s) throw notFound("Show not found");
    return s;
  }

  create(title: string): Show {
    if (this.d.store.doc.shows.length >= 200) throw conflict("You have too many shows. Delete some old ones first.");
    const firstDevice = this.d.store.devices()[0]?.id ?? null;
    const at = this.iso();
    const show: Show = {
      id: newId("s"),
      title,
      createdAt: at,
      updatedAt: at,
      config: defaultConfig(firstDevice),
      outputs: { record: true, destinationIds: [] },
      fps: DEFAULT_FPS as 30 | 60,
      videoKbps: DEFAULT_VIDEO_KBPS,
      state: "IDLE",
      liveSince: null,
      link: null,
    };
    this.d.store.doc.shows.push(show);
    this.d.store.save();
    return show;
  }

  update(id: string, input: UpdateShowInput): Show {
    const s = this.get(id);
    const live = s.state === "LIVE";
    if (live && (input.fps !== undefined || input.videoKbps !== undefined || input.outputs !== undefined || input.link !== undefined)) {
      const same =
        (input.fps === undefined || input.fps === s.fps) &&
        (input.videoKbps === undefined || input.videoKbps === s.videoKbps) &&
        (input.outputs === undefined || JSON.stringify(input.outputs) === JSON.stringify(s.outputs)) &&
        (input.link === undefined || JSON.stringify(input.link) === JSON.stringify(s.link));
      if (!same) throw conflict("End the show before changing its outputs or quality.");
    }
    if (input.outputs) {
      const known = new Set(this.d.store.doc.destinations.map((x) => x.id));
      const bad = input.outputs.destinationIds.find((x) => !known.has(x));
      if (bad) throw new HttpError(400, "VALIDATION_ERROR", "One of the stream keys no longer exists. Reload and try again.", { "outputs.destinationIds": "Unknown stream key" });
    }
    let bump = false;
    if (input.title !== undefined && input.title !== s.title) {
      s.title = input.title;
      bump = true;
    }
    if (input.config !== undefined) {
      s.config = input.config;
      bump = true;
    }
    if (input.outputs !== undefined) s.outputs = { record: input.outputs.record, destinationIds: [...new Set(input.outputs.destinationIds)] };
    if (input.fps !== undefined) s.fps = input.fps;
    if (input.videoKbps !== undefined) s.videoKbps = input.videoKbps;
    if (input.link !== undefined) s.link = input.link;
    s.updatedAt = this.iso();
    this.d.store.save();
    if (bump) this.bump(id);
    return s;
  }

  remove(id: string) {
    const s = this.get(id);
    if (s.state === "LIVE") throw conflict("End the show before deleting it.");
    this.d.store.doc.shows = this.d.store.doc.shows.filter((x) => x.id !== id);
    this.d.store.save();
    this.controls.delete(id);
    this.runtimes.delete(id);
    this.wake(id);
  }

  /** a stream key was removed: drop it from every show's outputs */
  forgetDestination(destId: string) {
    let changed = false;
    for (const s of this.d.store.doc.shows) {
      if (s.outputs.destinationIds.includes(destId)) {
        s.outputs.destinationIds = s.outputs.destinationIds.filter((x) => x !== destId);
        changed = true;
      }
    }
    if (changed) this.d.store.save();
  }

  // ---------------------------------------------------------------- control + long-poll

  private control(id: string): Control {
    let c = this.controls.get(id);
    if (!c) {
      // a fresh number per boot, so a renderer holding an old version gets an answer at once
      c = { version: 1, programId: null, takeSeq: 0 };
      this.controls.set(id, c);
    }
    return c;
  }

  private wake(id: string) {
    const w = this.waiters.get(id);
    if (!w) return;
    this.waiters.delete(id);
    for (const f of w) f();
  }

  bump(id: string) {
    this.control(id).version++;
    this.wake(id);
  }

  controlState(id: string): ControlState {
    const s = this.get(id);
    const c = this.control(id);
    return { ...c, config: s.config, title: s.title, state: s.state, liveSince: s.liveSince };
  }

  /** Answers at once when `since` isn't the current version; otherwise waits for a change (≤ waitMs). */
  async waitControl(id: string, since: number | null, signal?: AbortSignal, waitMs = LONG_POLL_MS): Promise<ControlState> {
    this.get(id);
    if (since === null || since !== this.control(id).version) return this.controlState(id);
    await new Promise<void>((resolve) => {
      let set = this.waiters.get(id);
      if (!set) {
        set = new Set();
        this.waiters.set(id, set);
      }
      const done = () => {
        clearTimeout(timer);
        signal?.removeEventListener("abort", done);
        this.waiters.get(id)?.delete(done);
        resolve();
      };
      const timer = setTimeout(done, waitMs);
      signal?.addEventListener("abort", done);
      set.add(done);
    });
    return this.controlState(id);
  }

  setControl(id: string, input: { programId: string | null; takeSeq: number }): { version: number } {
    this.get(id);
    const c = this.control(id);
    c.programId = input.programId;
    c.takeSeq = input.takeSeq;
    c.version++;
    this.wake(id);
    return { version: c.version };
  }

  // ---------------------------------------------------------------- live

  liveShow(): Show | undefined {
    return this.d.store.doc.shows.find((s) => s.state === "LIVE");
  }

  status(id: string): ShowStatus {
    const s = this.get(id);
    const rt = this.runtimes.get(id);
    const last = rt?.pipeline ? rt.last : null;
    const outputs: ShowStatus["outputs"] = [];
    if (rt && s.state === "LIVE") {
      for (const t of rt.targets) {
        const o = last?.outputs.find((x) => x.id === t.id);
        outputs.push({ id: t.id, name: t.name, kind: t.kind, ok: o ? o.ok : last?.state === "live", error: o?.error ?? null });
      }
      if (rt.integration?.error) outputs.push({ id: `integration:${rt.integration.id}`, name: rt.integration.name, kind: "rtmp", ok: false, error: rt.integration.error });
    }
    const rendererState = s.state === "LIVE" ? (last?.state ?? "starting") : rt?.error ? "error" : "idle";
    return {
      state: s.state,
      liveSince: s.liveSince,
      renderer: {
        state: rendererState,
        fps: s.state === "LIVE" ? (last?.fps ?? null) : null,
        encoder: last?.encoder ?? this.lastEncoder,
        bitrateKbps: s.state === "LIVE" ? (last?.bitrateKbps ?? null) : null,
        error: s.state === "LIVE" ? (last?.error ?? null) : (rt?.error ?? null),
      },
      outputs,
      recordingFile: s.state === "LIVE" ? (last?.recordingFile ?? null) : null,
      integration: rt?.integration && s.state === "LIVE" ? { ...rt.integration } : null,
    };
  }

  /** what the show would send to (without the integration's targets, which come from startBroadcast) */
  buildTargets(s: Show): PipelineTarget[] {
    const targets: PipelineTarget[] = [];
    if (s.outputs.record) targets.push({ id: "record", name: "Recording on this PC", kind: "record", url: this.d.store.recordingsDir });
    for (const id of s.outputs.destinationIds) {
      const dest = this.d.store.doc.destinations.find((x) => x.id === id);
      if (dest) targets.push({ id: `dest:${dest.id}`, name: dest.name, kind: "rtmp", url: joinStreamKey(dest.url, dest.streamKey) });
    }
    targets.push({ id: "preview", name: "Program preview", kind: "preview", url: this.d.previewUrl(s.id) });
    return targets;
  }

  async start(id: string): Promise<ShowStatus> {
    const s = this.get(id);
    if (s.state === "LIVE") return this.status(id);
    const other = this.liveShow();
    if (other) throw conflict(`"${other.title}" is live right now. End it first: one show at a time.`);

    const integration = s.link ? this.d.integrations.get(s.link.integration) : undefined;
    const wantsIntegration = !!integration && integration.info().connected && (s.link?.outputIds.length ?? 0) > 0;
    const targets = this.buildTargets(s);
    if (targets.length === 1 && !wantsIntegration) {
      throw new HttpError(400, "NO_OUTPUTS", "Turn on 'Record on this PC' or a stream key first.");
    }

    // claim the live slot before any await, so two quick clicks can't start two shows
    s.state = "LIVE";
    s.liveSince = this.iso();
    s.updatedAt = s.liveSince;
    const rt: Runtime = { pipeline: null, targets, last: null, error: null, integration: null, heartbeat: null, stopping: false };
    this.runtimes.set(id, rt);
    this.d.store.save();
    this.bump(id);

    if (integration && wantsIntegration) {
      rt.integration = { id: integration.id, name: integration.name, broadcastId: null, watchUrl: null, error: null };
      try {
        const b = await integration.startBroadcast(s);
        rt.integration.broadcastId = b.broadcastId;
        rt.integration.watchUrl = b.watchUrl;
        for (const t of b.targets) targets.push({ id: `int:${integration.id}:${t.id}`, name: t.name, kind: "rtmp", url: t.url });
      } catch (e) {
        rt.integration.error = e instanceof HttpError ? e.message : `${integration.name} didn't answer.`;
        this.log(`show ${id}: integration ${integration.id} failed at start: ${rt.integration.error}`);
      }
      // stop was pressed while we waited
      if (rt.stopping || this.runtimes.get(id) !== rt) {
        const late = rt.integration.broadcastId;
        if (late) await integration.stopBroadcast(late).catch(() => {});
        return this.status(id);
      }
    }

    try {
      const opts: PipelineOptions = {
        showId: s.id,
        title: s.title,
        slug: slugify(s.title),
        renderUrl: this.d.renderUrl(s.id),
        fps: s.fps,
        videoKbps: s.videoKbps,
        targets: [...targets],
        ffmpegPath: this.d.ffmpegPath,
        chromePath: this.d.chromePath,
        encoder: this.d.encoder,
        onStatus: (st) => {
          if (this.runtimes.get(id) !== rt || rt.stopping) return;
          rt.last = st;
          if (st.encoder) this.lastEncoder = st.encoder;
        },
        onExit: (reason) => {
          if (this.runtimes.get(id) !== rt || rt.stopping) return;
          this.log(`show ${id}: renderer stopped: ${reason}`);
          void this.finish(id, rt, reason);
        },
      };
      rt.pipeline = this.d.startPipeline(opts);
      rt.last = rt.pipeline.status();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      this.log(`show ${id}: renderer failed to start: ${msg}`);
      await this.finish(id, rt, `The renderer couldn't start: ${msg}`);
      throw new HttpError(500, "RENDERER_FAILED", `The show couldn't start: ${msg}`);
    }

    if (integration && rt.integration?.broadcastId) {
      const broadcastId = rt.integration.broadcastId;
      rt.heartbeat = setInterval(() => {
        const last = rt.last;
        integration
          .heartbeat(broadcastId, { state: last?.state ?? "starting", fps: last?.fps ?? null, bitrateKbps: last?.bitrateKbps ?? null })
          .then((r) => {
            if (rt.integration) rt.integration.error = null;
            if (r.stop && this.runtimes.get(id) === rt && !rt.stopping) {
              this.log(`show ${id}: ${integration.name} asked to end the show`);
              void this.stop(id);
            }
          })
          .catch((e) => {
            if (rt.integration) rt.integration.error = e instanceof HttpError ? e.message : `${integration.name} didn't answer.`;
          });
      }, INTEGRATION_HEARTBEAT_MS);
      rt.heartbeat.unref?.();
    }
    return this.status(id);
  }

  /** End the live state: stop the pipeline (unless it already exited), the heartbeat and the integration broadcast. */
  private async finish(id: string, rt: Runtime, error: string | null) {
    if (rt.stopping) return;
    rt.stopping = true;
    if (rt.heartbeat) clearInterval(rt.heartbeat);
    rt.heartbeat = null;
    const p = rt.pipeline;
    rt.pipeline = null;
    rt.error = error;
    const s = this.d.store.doc.shows.find((x) => x.id === id);
    if (s && s.state === "LIVE") {
      s.state = "IDLE";
      s.liveSince = null;
      s.updatedAt = this.iso();
      this.d.store.save();
      this.bump(id);
    }
    const tasks: Promise<unknown>[] = [];
    if (p) tasks.push(p.stop().catch((e) => this.log(`show ${id}: pipeline stop failed: ${e instanceof Error ? e.message : e}`)));
    const integ = rt.integration;
    if (integ?.broadcastId) {
      const it = this.d.integrations.get(integ.id);
      if (it) tasks.push(it.stopBroadcast(integ.broadcastId).catch((e) => this.log(`show ${id}: ${integ.id} stopBroadcast failed: ${e instanceof Error ? e.message : e}`)));
    }
    await Promise.all(tasks);
  }

  async stop(id: string): Promise<ShowStatus> {
    const s = this.get(id);
    const rt = this.runtimes.get(id);
    if (rt && !rt.stopping) await this.finish(id, rt, null);
    else if (s.state === "LIVE") {
      s.state = "IDLE";
      s.liveSince = null;
      this.d.store.save();
      this.bump(id);
    }
    return this.status(id);
  }

  /** server shutdown */
  async stopAll() {
    await Promise.all([...this.runtimes.entries()].filter(([, rt]) => !rt.stopping).map(([id, rt]) => this.finish(id, rt, null)));
  }
}
