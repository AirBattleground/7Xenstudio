/** Test helpers for the server tests: a studio on a random port with a fake pipeline and a fake media server. */
import http from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { createStudio, type Studio } from "../src/server/app.js";
import { loadConfig, type Config } from "../src/server/config.js";
import type { IntegrationFactory } from "../src/server/integrations/registry.js";
import type { Media } from "../src/server/media.js";
import type { PipelineOptions, PipelineStatus, StartPipeline } from "../src/server/pipeline/types.js";

export class FakeMedia implements Media {
  ready = new Set<string>();
  kicked: string[] = [];
  async fetchHls(mediaPath: string, file: string, search: string) {
    if (!this.ready.has(mediaPath)) return new Response("nope", { status: 404 });
    return new Response(`#EXTM3U\n# ${mediaPath}/${file}${search}\n`, { status: 200, headers: { "content-type": "application/vnd.apple.mpegurl" } });
  }
  async pathReady(mediaPath: string) {
    return this.ready.has(mediaPath) ? { readySince: new Date("2026-10-21T10:00:00Z") } : null;
  }
  async kick(mediaPath: string) {
    this.kicked.push(mediaPath);
  }
}

export interface FakeRun {
  opts: PipelineOptions;
  stopped: boolean;
  status: PipelineStatus;
}

export function fakePipeline() {
  const runs: FakeRun[] = [];
  const start: StartPipeline = (opts) => {
    const run: FakeRun = {
      opts,
      stopped: false,
      status: { state: "live", fps: opts.fps, encoder: "libx264", bitrateKbps: opts.videoKbps, error: null, outputs: opts.targets.map((t) => ({ id: t.id, ok: true, error: null })), recordingFile: null, restarts: 0 },
    };
    runs.push(run);
    queueMicrotask(() => opts.onStatus(run.status));
    return {
      status: () => run.status,
      stop: async () => {
        run.stopped = true;
      },
    };
  };
  return { runs, start };
}

export interface TestStudio {
  studio: Studio;
  base: string;
  cfg: Config;
  media: FakeMedia;
  pipeline: ReturnType<typeof fakePipeline>;
  close(): Promise<void>;
  req(method: string, p: string, body?: unknown, headers?: Record<string, string>): Promise<{ status: number; body: any; headers: Headers }>;
}

export async function startTestStudio(env: Record<string, string> = {}, integrations?: IntegrationFactory[]): Promise<TestStudio> {
  const dir = mkdtempSync(path.join(os.tmpdir(), "studio-test-"));
  const cfg = loadConfig({ DATA_DIR: dir, LAN_HOST: "192.168.1.50", PORT: "4400", WEB_DIST: path.join(dir, "no-web"), ...env });
  const media = new FakeMedia();
  const pipeline = fakePipeline();
  const studio = createStudio(cfg, { startPipeline: pipeline.start, media, integrations, log: () => {} });
  const server = http.createServer(studio.handler);
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  return {
    studio,
    base,
    cfg,
    media,
    pipeline,
    async close() {
      studio.integrations.dispose();
      server.closeAllConnections();
      await new Promise<void>((r) => server.close(() => r()));
      rmSync(dir, { recursive: true, force: true });
    },
    async req(method, p, body, headers = {}) {
      const res = await fetch(base + p, {
        method,
        headers: { ...(body !== undefined && !(body instanceof FormData) ? { "content-type": "application/json" } : {}), ...headers },
        body: body === undefined ? undefined : body instanceof FormData ? body : JSON.stringify(body),
      });
      const text = await res.text();
      let parsed: unknown = text;
      try {
        parsed = text ? JSON.parse(text) : null;
      } catch {
        /* not JSON */
      }
      return { status: res.status, body: parsed, headers: res.headers };
    },
  };
}
