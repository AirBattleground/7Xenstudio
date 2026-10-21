import { describe, expect, it } from "vitest";
import { backoffMs, FatalError, Supervisor, type Attempt, type AttemptHooks, type Launch } from "../src/server/pipeline/runner.js";

/** Fake Chrome+ffmpeg attempts driven by the test. */
function fakes(opts: { failLaunch?: (n: number) => Error | null } = {}) {
  let t = 0;
  const attempts: { n: number; hooks: AttemptHooks; stopped: boolean; flowing: boolean }[] = [];
  const fatal: string[] = [];
  const launch: Launch = async (hooks, n) => {
    const err = opts.failLaunch?.(n);
    if (err) throw err;
    const a = { n, hooks, stopped: false, flowing: false };
    attempts.push(a);
    const attempt: Attempt = { flowing: () => a.flowing, stop: async () => void (a.stopped = true) };
    return attempt;
  };
  const sup = new Supervisor(launch, { now: () => t, onFatal: (r) => fatal.push(r) });
  return {
    sup,
    attempts,
    fatal,
    advance: async (ms: number) => {
      t += ms;
      await sup.tick();
    },
    last: () => attempts[attempts.length - 1]!,
    /** chunk + ffmpeg progress with out_time advancing */
    flow: async () => {
      const a = attempts[attempts.length - 1]!;
      a.flowing = true;
      a.hooks.chunk();
      a.hooks.progress();
      await sup.tick();
    },
  };
}

describe("Supervisor", () => {
  it("starting → live only once a chunk arrived AND ffmpeg progresses", async () => {
    const f = fakes();
    await f.sup.start();
    expect(f.sup.state).toBe("starting");
    f.last().hooks.chunk();
    await f.sup.tick();
    expect(f.sup.state).toBe("starting"); // chunk but no ffmpeg progress yet
    f.last().flowing = true;
    f.last().hooks.progress();
    expect(f.sup.state).toBe("live");
    expect(f.sup.error).toBeNull();
  });

  it("no first chunk within 30 s → restart both with backoff 2, 4, 8 … 30 s", async () => {
    const f = fakes();
    await f.sup.start();
    await f.advance(30_000);
    expect(f.sup.state).toBe("starting");
    await f.advance(1);
    expect(f.sup.state).toBe("error");
    expect(f.sup.error).toMatch(/no video within 30 s/);
    expect(f.attempts[0]!.stopped).toBe(true);
    await f.advance(1999);
    expect(f.attempts).toHaveLength(1);
    await f.advance(1);
    expect(f.attempts).toHaveLength(2);
    expect(f.sup.restarts).toBe(1);
    expect(f.sup.state).toBe("starting");
    expect([1, 2, 3, 4, 5, 6].map(backoffMs)).toEqual([2000, 4000, 8000, 16_000, 30_000, 30_000]);
  });

  it("chunks stop for 15 s while live → restart", async () => {
    const f = fakes();
    await f.sup.start();
    await f.flow();
    await f.advance(15_000);
    expect(f.sup.state).toBe("live");
    f.last().hooks.chunk();
    await f.advance(15_001);
    expect(f.sup.state).toBe("error");
    expect(f.sup.error).toMatch(/No video from the render page for 15 s/);
    await f.advance(2000);
    expect(f.attempts).toHaveLength(2);
  });

  it("ffmpeg exit or page crash → restart both; old attempt's hooks are ignored", async () => {
    const f = fakes();
    await f.sup.start();
    await f.flow();
    const first = f.last();
    first.hooks.exit("The encoder (ffmpeg) stopped (code 1)");
    await f.sup.tick();
    expect(f.sup.state).toBe("error");
    expect(first.stopped).toBe(true);
    first.hooks.exit("again"); // stale
    first.hooks.chunk();
    await f.advance(2000);
    expect(f.attempts).toHaveLength(2);
    expect(f.sup.state).toBe("starting");
    // second failure waits 4 s
    f.last().hooks.exit("The render page crashed");
    await f.sup.tick();
    expect(f.sup.error).toBe("The render page crashed");
    await f.advance(3999);
    expect(f.attempts).toHaveLength(2);
    await f.advance(1);
    expect(f.attempts).toHaveLength(3);
  });

  it("backoff starts over after 30 s live", async () => {
    const f = fakes();
    await f.sup.start();
    f.last().hooks.exit("x");
    await f.sup.tick();
    await f.advance(2000); // attempt 2
    f.last().hooks.exit("x");
    await f.sup.tick();
    await f.advance(4000); // attempt 3
    await f.flow();
    for (let i = 0; i < 4; i++) {
      f.last().hooks.chunk();
      await f.advance(10_000);
    }
    f.last().hooks.exit("x");
    await f.sup.tick();
    await f.advance(2000);
    expect(f.attempts).toHaveLength(4);
  });

  it("a launch error retries; a FatalError gives up once", async () => {
    const f = fakes({ failLaunch: (n) => (n === 1 ? new Error("Chrome could not start: boom") : n === 2 ? new FatalError("Google Chrome is not installed on this PC.") : null) });
    await f.sup.start();
    expect(f.sup.state).toBe("error");
    expect(f.sup.error).toMatch(/boom/);
    await f.advance(2000);
    expect(f.sup.state).toBe("error");
    expect(f.fatal).toEqual(["Google Chrome is not installed on this PC."]);
    await f.advance(60_000);
    expect(f.attempts).toHaveLength(0);
  });

  it("stop() stops the attempt and ignores everything afterwards", async () => {
    const f = fakes();
    await f.sup.start();
    await f.flow();
    const a = f.last();
    await f.sup.stop();
    expect(a.stopped).toBe(true);
    expect(f.sup.state).toBe("stopped");
    a.hooks.exit("late");
    await f.advance(60_000);
    expect(f.attempts).toHaveLength(1);
  });

  it("an attempt that finishes launching after stop() is stopped at once", async () => {
    let release!: () => void;
    const stopped: boolean[] = [];
    const sup = new Supervisor(async () => {
      await new Promise<void>((r) => (release = r));
      return { flowing: () => true, stop: async () => void stopped.push(true) };
    });
    void sup.start();
    await Promise.resolve();
    const done = sup.stop();
    release();
    await done;
    expect(stopped).toEqual([true]);
  });
});
