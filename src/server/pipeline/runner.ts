/**
 * Restart state machine for one show's renderer.
 *
 * An "attempt" is Chrome + ffmpeg together: the WebM header only comes in the page recorder's first chunk, so the
 * two always (re)start as a pair. The supervisor keeps an attempt running:
 *   - first chunk must arrive within `firstChunkMs` (30 s), then at least one every `stallMs` (15 s) → else restart
 *   - ffmpeg exit / page crash or close (hooks.exit) → restart
 *   - restarts back off 2, 4, 8 … 30 s; state "error" with a plain-English message meanwhile
 *   - "live" only once a chunk arrived AND ffmpeg reports progress with out_time advancing
 *   - a FatalError from launch (ffmpeg / Chrome missing) → give up for good (onFatal, once)
 * Everything is serialized through one queue so a tick and a crash never race; hooks of an old attempt are ignored.
 */
import { log } from "./log.js";

export type SupervisorState = "starting" | "live" | "error" | "stopped";

export interface Attempt {
  /** ffmpeg is writing output (out_time advancing) */
  flowing(): boolean;
  stop(): Promise<void>;
}

export interface AttemptHooks {
  /** a chunk reached ffmpeg */
  chunk(): void;
  /** ffmpeg reported progress */
  progress(): void;
  /** Chrome or ffmpeg died */
  exit(reason: string): void;
}

export type Launch = (hooks: AttemptHooks, attempt: number) => Promise<Attempt>;

/** Retrying cannot help (ffmpeg or Chrome missing). */
export class FatalError extends Error {}

export interface SupervisorOpts {
  now?: () => number;
  stallMs?: number;
  firstChunkMs?: number;
  /** live this long without trouble → the backoff starts over */
  healthyMs?: number;
  /** state / error / restarts changed */
  onChange?: () => void;
  /** gave up for good */
  onFatal?: (reason: string) => void;
}

export function backoffMs(failures: number): number {
  return Math.min(30_000, 1000 * 2 ** Math.max(1, failures));
}

export class Supervisor {
  state: SupervisorState = "starting";
  error: string | null = null;
  /** attempts started after the first one */
  restarts = 0;
  private attempt: Attempt | null = null;
  private gen = 0;
  private launched = 0;
  private failures = 0;
  private nextAttemptAt: number | null = null;
  private startedAt = 0;
  private lastChunkAt: number | null = null;
  private liveSince: number | null = null;
  private queue: Promise<void> = Promise.resolve();
  private readonly now: () => number;
  private readonly stallMs: number;
  private readonly firstChunkMs: number;
  private readonly healthyMs: number;

  constructor(
    private readonly launch: Launch,
    private readonly opts: SupervisorOpts = {},
  ) {
    this.now = opts.now ?? Date.now;
    this.stallMs = opts.stallMs ?? 15_000;
    this.firstChunkMs = opts.firstChunkMs ?? 30_000;
    this.healthyMs = opts.healthyMs ?? 30_000;
  }

  /** (a method so TypeScript doesn't narrow `state` across awaits) */
  isStopped(): boolean {
    return this.state === "stopped";
  }

  get running() {
    return this.attempt !== null;
  }

  private enqueue(fn: () => Promise<void> | void): Promise<void> {
    this.queue = this.queue.then(fn).catch((err) => log.error("renderer supervisor error", { err }));
    return this.queue;
  }

  private changed() {
    if (this.state !== "stopped") this.opts.onChange?.();
  }

  /** First attempt. */
  start(): Promise<void> {
    return this.enqueue(() => this.run());
  }

  /** Call often (twice a second): stall detection, backoff retries, healthy reset. */
  tick(): Promise<void> {
    return this.enqueue(async () => {
      if (this.state === "stopped" || (this.state === "error" && this.nextAttemptAt === null && !this.attempt)) return;
      const now = this.now();
      if (!this.attempt) {
        if (this.nextAttemptAt !== null && now >= this.nextAttemptAt) await this.run();
        return;
      }
      const since = this.lastChunkAt ?? this.startedAt;
      const limit = this.lastChunkAt === null ? this.firstChunkMs : this.stallMs;
      if (now - since > limit) {
        await this.fail(
          this.lastChunkAt === null
            ? `The render page sent no video within ${Math.round(limit / 1000)} s. Restarting it.`
            : `No video from the render page for ${Math.round(limit / 1000)} s. Restarting it.`,
          this.gen,
        );
        return;
      }
      this.maybeLive();
      if (this.state === "live" && this.liveSince !== null && now - this.liveSince > this.healthyMs) this.failures = 0;
    });
  }

  /** Stop for good: no more restarts, no more callbacks. */
  stop(): Promise<void> {
    // synchronously, so an attempt that is still launching is thrown away as soon as it returns
    this.state = "stopped";
    return this.enqueue(async () => {
      this.nextAttemptAt = null;
      await this.teardown();
    });
  }

  private maybeLive() {
    if (this.state !== "starting" || this.lastChunkAt === null || !this.attempt) return;
    if (!this.attempt.flowing()) return;
    this.state = "live";
    this.liveSince = this.now();
    this.error = null;
    log.info("Renderer live");
    this.changed();
  }

  private async run() {
    if (this.state === "stopped") return;
    const g = ++this.gen;
    if (this.launched++ > 0) this.restarts++;
    this.state = "starting";
    this.nextAttemptAt = null;
    this.startedAt = this.now();
    this.lastChunkAt = null;
    this.liveSince = null;
    this.changed();
    const hooks: AttemptHooks = {
      chunk: () => {
        if (g !== this.gen) return;
        this.lastChunkAt = this.now();
        this.maybeLive();
      },
      progress: () => {
        if (g === this.gen) this.maybeLive();
      },
      exit: (reason) => {
        if (g === this.gen) void this.enqueue(() => this.fail(reason, g));
      },
    };
    try {
      const a = await this.launch(hooks, this.launched);
      if (g !== this.gen || this.isStopped()) {
        // it failed (or was stopped) while starting
        await a.stop().catch(() => {});
        return;
      }
      this.attempt = a;
      this.maybeLive();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (err instanceof FatalError) await this.giveUp(msg, g);
      else await this.fail(msg, g);
    }
  }

  private async giveUp(reason: string, g: number) {
    if (g !== this.gen || this.state === "stopped") return;
    await this.teardown();
    this.state = "error";
    this.error = reason.slice(0, 300);
    this.nextAttemptAt = null;
    log.error(`${reason} — giving up`);
    this.opts.onChange?.();
    this.opts.onFatal?.(this.error);
  }

  private async fail(reason: string, g: number) {
    if (g !== this.gen || this.state === "stopped") return;
    await this.teardown();
    this.failures++;
    this.state = "error";
    this.error = reason.slice(0, 300);
    const wait = backoffMs(this.failures);
    this.nextAttemptAt = this.now() + wait;
    log.warn(`${reason} — retrying in ${Math.round(wait / 1000)} s`);
    this.changed();
  }

  private async teardown() {
    this.gen++;
    const a = this.attempt;
    this.attempt = null;
    this.lastChunkAt = null;
    this.liveSince = null;
    if (a) await a.stop().catch((err) => log.warn("renderer stop failed", { err }));
  }
}
