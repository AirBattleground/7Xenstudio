import { writeFileSync, utimesSync } from "node:fs";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { RENDER_TOKEN_HEADER, type Show } from "../src/shared/types.js";
import { authorizeMedia } from "../src/server/media.js";
import { joinStreamKey } from "../src/server/shows.js";
import { PUBLISH_TOKEN_TTL_MS, Tokens } from "../src/server/tokens.js";
import { startTestStudio, type TestStudio } from "./server-helpers.js";

describe("tokens", () => {
  const t = new Tokens(Buffer.alloc(32, 7));
  it("publish token verifies for that device + key only, until it expires", () => {
    const now = 1_000_000;
    const { token, expiresAt } = t.publishToken("dev12345", "hashA", now);
    expect(expiresAt.getTime()).toBe(now + PUBLISH_TOKEN_TTL_MS);
    expect(t.verifyPublishToken("dev12345", "hashA", token, now + 1000)).toBe(true);
    expect(t.verifyPublishToken("dev12345", "hashB", token, now)).toBe(false);
    expect(t.verifyPublishToken("other123", "hashA", token, now)).toBe(false);
    expect(t.verifyPublishToken("dev12345", "hashA", token, now + PUBLISH_TOKEN_TTL_MS + 1)).toBe(false);
  });
  it("render token names its show and can't be forged", () => {
    const tok = t.renderToken("sabcdef123");
    expect(t.verifyRenderToken(tok)).toBe("sabcdef123");
    expect(t.verifyRenderToken(tok.replace("sabcdef123", "sother1234"))).toBeNull();
    expect(t.verifyRenderToken("garbage")).toBeNull();
    expect(new Tokens(Buffer.alloc(32, 8)).verifyRenderToken(tok)).toBeNull();
  });
  it("session cookie is tied to the PIN", () => {
    const c = t.sessionCookie("1234");
    expect(t.verifySession("1234", c.value)).toBe(true);
    expect(t.verifySession("9999", c.value)).toBe(false);
  });
});

describe("media auth hook", () => {
  const tokens = new Tokens(Buffer.alloc(32, 1));
  const deps = { tokens, deviceKeyHash: (id: string) => (id === "dev12345" ? "kh" : undefined) };
  const tok = tokens.publishToken("dev12345", "kh").token;
  it.each([
    [{ action: "publish", path: "live/dev_dev12345", query: `token=${tok}`, ip: "192.168.1.5" }, true],
    [{ action: "publish", path: "live/dev_dev12345", query: "token=1.x", ip: "192.168.1.5" }, false],
    [{ action: "publish", path: "live/dev_unknown1", query: `token=${tok}`, ip: "192.168.1.5" }, false],
    [{ action: "publish", path: "live/show_abcdefgh1", ip: "127.0.0.1" }, true],
    [{ action: "publish", path: "live/show_abcdefgh1", ip: "192.168.1.5" }, false],
    [{ action: "read", path: "live/dev_dev12345", ip: "127.0.0.1" }, true],
    [{ action: "read", path: "live/dev_dev12345", ip: "::ffff:127.0.0.1" }, true],
    [{ action: "read", path: "live/dev_dev12345", ip: "192.168.1.9" }, false],
    [{ action: "api", ip: "127.0.0.1" }, false],
    [{ action: "api", user: "studio", password: tokens.internalPass, ip: "192.168.1.9" }, true],
  ])("%j → %s", (req, ok) => {
    expect(authorizeMedia(req, deps)).toBe(ok);
  });
});

describe("stream key URLs", () => {
  it("joins with exactly one slash", () => {
    expect(joinStreamKey("rtmp://a.rtmp.youtube.com/live2", "abcd")).toBe("rtmp://a.rtmp.youtube.com/live2/abcd");
    expect(joinStreamKey("rtmps://live-api-s.facebook.com:443/rtmp/", "FB-1")).toBe("rtmps://live-api-s.facebook.com:443/rtmp/FB-1");
  });
});

describe("studio server", () => {
  let s: TestStudio;
  beforeEach(async () => {
    s = await startTestStudio();
  });
  afterEach(() => s.close());

  it("info is open and says no PIN", async () => {
    const r = await s.req("GET", "/api/info");
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ name: "7XEN Studio", lanUrl: "http://192.168.1.50:4400", mediaRtmp: "rtmp://192.168.1.50:1940/live", pinRequired: false, authed: true });
    const p = await s.req("PATCH", "/api/settings", { name: "Arena PC" });
    expect(p.body.name).toBe("Arena PC");
  });

  it("device API: create → hello → stream/start → heartbeat → row; 401 for a bad key", async () => {
    const c = await s.req("POST", "/api/devices", { name: "Cam phone" });
    expect(c.status).toBe(201);
    const { device, key, pairUrl } = c.body;
    expect(key).toMatch(/^7xk_/);
    expect(pairUrl).toContain("7xen://pair?host=http%3A%2F%2F192.168.1.50%3A4400");
    const H = { "X-Device-Key": key };

    const bad = await s.req("POST", "/api/device/hello", {}, { "X-Device-Key": "7xk_nope" });
    expect(bad.status).toBe(401);
    expect(bad.body.error.code).toBe("DEVICE_KEY_INVALID");

    const hello = await s.req("POST", "/api/device/hello", { deviceModel: "iPhone15,2", osVersion: "18.1", appVersion: "1.2" }, H);
    expect(hello.body).toEqual({ device: { id: device.id, name: "Cam phone" }, manager: { name: "7XEN Studio" }, studio: { name: "7XEN Studio" }, assignedMatch: null });

    const start = await s.req("POST", "/api/device/stream/start", { quality: "720p", fps: 60 }, H);
    expect(start.body.rtmpUrl).toBe("rtmp://192.168.1.50:1940/live");
    expect(start.body.streamName).toMatch(new RegExp(`^dev_${device.id}\\?token=\\d+\\.`));
    const token = start.body.streamName.split("token=")[1];
    expect(authorizeMedia({ action: "publish", path: `live/dev_${device.id}`, query: `token=${token}`, ip: "10.0.0.9" }, { tokens: s.studio.tokens, deviceKeyHash: (id) => s.studio.store.device(id)?.keyHash })).toBe(true);

    const hb = await s.req("POST", "/api/device/heartbeat", { state: "LIVE", battery: 0.8, fps: 60 }, H);
    expect(hb.body).toEqual({ assignedMatch: null, snapshotRequests: [] });

    s.media.ready.add(`live/dev_${device.id}`);
    const list = await s.req("GET", "/api/devices");
    expect(list.body.items[0]).toMatchObject({ id: device.id, model: "iPhone15,2", online: true, streaming: true, videoReady: true, hlsUrl: `/api/devices/${device.id}/live/index.m3u8` });
    expect(list.body.items[0].health).toMatchObject({ battery: 0.8, fps: 60 });

    const hls = await s.req("GET", `/api/devices/${device.id}/live/index.m3u8`);
    expect(hls.status).toBe(200);
    expect(hls.body).toContain(`live/dev_${device.id}/index.m3u8`);

    expect((await s.req("POST", "/api/device/stream/stop", {}, H)).status).toBe(204);
    expect((await s.req("DELETE", `/api/devices/${device.id}`)).status).toBe(204);
    expect(s.media.kicked).toContain(`live/dev_${device.id}`);
    expect((await s.req("POST", "/api/device/heartbeat", {}, H)).status).toBe(401);
  });

  it("snapshot rides on the heartbeat", async () => {
    const { device, key } = (await s.req("POST", "/api/devices", { name: "Phone" })).body;
    const pending = s.req("GET", `/api/devices/${device.id}/snapshot.png`);
    await new Promise((r) => setTimeout(r, 50));
    const hb = await s.req("POST", "/api/device/heartbeat", {}, { "X-Device-Key": key });
    expect(hb.body.snapshotRequests).toHaveLength(1);
    const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(32)]);
    const form = new FormData();
    form.append("image", new Blob([png], { type: "image/png" }), "s.png");
    const up = await s.req("POST", `/api/device/snapshots/${hb.body.snapshotRequests[0].id}`, form, { "X-Device-Key": key });
    expect(up.status).toBe(204);
    const r = await pending;
    expect(r.status).toBe(200);
    expect(r.headers.get("content-type")).toBe("image/png");
  });

  it("shows: default config, start builds targets, one live show at a time, stop", async () => {
    const dev = (await s.req("POST", "/api/devices", { name: "Phone A" })).body.device;
    const yt = (await s.req("POST", "/api/destinations", { kind: "YOUTUBE", name: "My channel", url: "rtmp://a.rtmp.youtube.com/live2/", streamKey: "abcd-1234" })).body;
    expect(yt.keyHint).toBe("1234");
    expect(yt.streamKey).toBeUndefined();

    const show: Show = (await s.req("POST", "/api/shows", { title: "Friday Finals!" })).body;
    expect(show.config.scenes.map((x) => x.name)).toEqual(["Starting soon", "Phone", "Host", "Break"]);
    expect(show.config.scenes[1]!.slots[0]).toEqual({ kind: "device", id: dev.id });
    expect(show).toMatchObject({ fps: 60, videoKbps: 6000, state: "IDLE", link: null, outputs: { record: true, destinationIds: [] } });

    await s.req("PATCH", `/api/shows/${show.id}`, { outputs: { record: true, destinationIds: [yt.id] }, fps: 30 });
    const st = await s.req("POST", `/api/shows/${show.id}/start`);
    expect(st.status).toBe(200);
    expect(st.body.state).toBe("LIVE");
    const run = s.pipeline.runs[0]!;
    expect(run.opts.fps).toBe(30);
    expect(run.opts.slug).toBe("friday-finals");
    expect(run.opts.renderUrl).toMatch(new RegExp(`^http://127\\.0\\.0\\.1:4400/render/${show.id}\\?t=`));
    expect(run.opts.targets).toEqual([
      { id: "record", name: "Recording on this PC", kind: "record", url: s.studio.store.recordingsDir },
      { id: `dest:${yt.id}`, name: "My channel", kind: "rtmp", url: "rtmp://a.rtmp.youtube.com/live2/abcd-1234" },
      { id: "preview", name: "Program preview", kind: "preview", url: `rtmp://127.0.0.1:1940/live/show_${show.id}` },
    ]);

    const status = (await s.req("GET", `/api/shows/${show.id}/status`)).body;
    expect(status.renderer).toMatchObject({ state: "live", fps: 30, encoder: "libx264" });
    expect(status.outputs).toHaveLength(3);

    const other = (await s.req("POST", "/api/shows", { title: "Other show" })).body;
    const clash = await s.req("POST", `/api/shows/${other.id}/start`);
    expect(clash.status).toBe(409);
    expect((await s.req("DELETE", `/api/shows/${show.id}`)).status).toBe(409);
    expect((await s.req("PATCH", `/api/shows/${show.id}`, { fps: 60 })).status).toBe(409);

    const stop = await s.req("POST", `/api/shows/${show.id}/stop`);
    expect(stop.body.state).toBe("IDLE");
    expect(run.stopped).toBe(true);
    expect((await s.req("POST", `/api/shows/${other.id}/start`)).status).toBe(200);
  });

  it("start without outputs is refused; pipeline exit ends the show honestly", async () => {
    const show = (await s.req("POST", "/api/shows", { title: "Nothing on" })).body;
    await s.req("PATCH", `/api/shows/${show.id}`, { outputs: { record: false, destinationIds: [] } });
    expect((await s.req("POST", `/api/shows/${show.id}/start`)).body.error.code).toBe("NO_OUTPUTS");
    await s.req("PATCH", `/api/shows/${show.id}`, { outputs: { record: true, destinationIds: [] } });
    await s.req("POST", `/api/shows/${show.id}/start`);
    s.pipeline.runs[0]!.opts.onExit("Chrome keeps crashing");
    await new Promise((r) => setTimeout(r, 20));
    const st = (await s.req("GET", `/api/shows/${show.id}/status`)).body;
    expect(st.state).toBe("IDLE");
    expect(st.renderer).toMatchObject({ state: "error", error: "Chrome keeps crashing" });
  });

  it("control long-poll answers at once for an old version and wakes on change", async () => {
    const show = (await s.req("POST", "/api/shows", { title: "Poll show" })).body;
    const first = (await s.req("GET", `/api/shows/${show.id}/control`)).body;
    expect(first).toMatchObject({ programId: null, takeSeq: 0, title: "Poll show", state: "IDLE" });
    const t0 = Date.now();
    const waiting = s.req("GET", `/api/shows/${show.id}/control?since=${first.version}`);
    await new Promise((r) => setTimeout(r, 100));
    const set = await s.req("PATCH", `/api/shows/${show.id}/control`, { programId: "phone", takeSeq: 1 });
    expect(set.body.version).toBe(first.version + 1);
    const woke = (await waiting).body;
    expect(Date.now() - t0).toBeLessThan(3000);
    expect(woke).toMatchObject({ version: first.version + 1, programId: "phone", takeSeq: 1 });
    // a title change bumps too
    const w2 = s.req("GET", `/api/shows/${show.id}/control?since=${woke.version}`);
    await s.req("PATCH", `/api/shows/${show.id}`, { title: "Renamed" });
    expect((await w2).body).toMatchObject({ title: "Renamed", version: woke.version + 1 });
  });

  it("recordings: list, Range, 409 while written, delete", async () => {
    const dir = s.studio.store.recordingsDir;
    const file = "2026-10-21_19-05-12_friday-finals_sabcdef1234567.mp4";
    writeFileSync(path.join(dir, file), Buffer.from("0123456789abcdef"));
    const list = (await s.req("GET", "/api/recordings")).body;
    expect(list.items[0]).toMatchObject({ file, title: "Friday finals", showId: "sabcdef1234567", sizeBytes: 16, recording: true });
    expect(list.disk.totalBytes).toBeGreaterThan(0);

    const res = await fetch(`${s.base}/api/recordings/${file}`, { headers: { Range: "bytes=4-7" } });
    expect(res.status).toBe(206);
    expect(res.headers.get("content-range")).toBe("bytes 4-7/16");
    expect(await res.text()).toBe("4567");
    const tail = await fetch(`${s.base}/api/recordings/${file}`, { headers: { Range: "bytes=-3" } });
    expect(await tail.text()).toBe("def");
    expect((await fetch(`${s.base}/api/recordings/${file}`, { headers: { Range: "bytes=99-" } })).status).toBe(416);
    const dl = await fetch(`${s.base}/api/recordings/${file}?download=1`);
    expect(dl.headers.get("content-disposition")).toContain("attachment");
    await dl.arrayBuffer();

    expect((await s.req("DELETE", `/api/recordings/${file}`)).status).toBe(409);
    const old = new Date(Date.now() - 60_000);
    utimesSync(path.join(dir, file), old, old);
    expect((await s.req("DELETE", `/api/recordings/${file}`)).status).toBe(204);
    expect((await s.req("GET", "/api/recordings/..%2Fstore.json")).status).toBe(404);
  });

  it("props: streamed upload, Range, size checks, delete", async () => {
    const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(5000, 1)]);
    const form = new FormData();
    form.append("name", "Team logo");
    form.append("file", new Blob([png], { type: "image/png" }), "logo.png");
    const up = await s.req("POST", "/api/props", form);
    expect(up.status).toBe(201);
    expect(up.body).toMatchObject({ name: "Team logo", kind: "image", sizeBytes: png.length });
    const r = await fetch(s.base + up.body.url, { headers: { Range: "bytes=0-3" } });
    expect(r.status).toBe(206);
    expect(Buffer.from(await r.arrayBuffer())).toEqual(png.subarray(0, 4));

    const vid = new FormData();
    vid.append("file", new Blob([Buffer.alloc(100_000, 2)], { type: "video/mp4" }), "intro.mp4");
    const v = await s.req("POST", "/api/props", vid);
    expect(v.body).toMatchObject({ name: "intro", kind: "video", sizeBytes: 100_000 });

    const big = new FormData();
    big.append("file", new Blob([Buffer.alloc(11 * 1024 * 1024, 3)], { type: "image/png" }), "huge.png");
    expect((await s.req("POST", "/api/props", big)).status).toBe(413);

    const junk = new FormData();
    junk.append("file", new Blob([Buffer.alloc(100, 0)], { type: "application/octet-stream" }), "x.bin");
    expect((await s.req("POST", "/api/props", junk)).status).toBe(400);

    expect((await s.req("GET", "/api/props")).body.items).toHaveLength(2);
    expect((await s.req("DELETE", `/api/props/${up.body.id}`)).status).toBe(204);
    expect((await s.req("GET", "/api/props")).body.items).toHaveLength(1);
  });

  it("boot turns LIVE shows back to IDLE", async () => {
    const show = (await s.req("POST", "/api/shows", { title: "Crashed show" })).body;
    await s.req("POST", `/api/shows/${show.id}/start`);
    const { Shows } = await import("../src/server/shows.js");
    const fresh = new Shows({ store: s.studio.store, integrations: s.studio.integrations, startPipeline: s.pipeline.start, renderUrl: () => "", previewUrl: () => "", ffmpegPath: null, chromePath: null, encoder: null });
    expect(fresh.get(show.id).state).toBe("IDLE");
  });
});

describe("PIN + render token", () => {
  let s: TestStudio;
  beforeEach(async () => {
    s = await startTestStudio({ STUDIO_PIN: "4321" });
  });
  afterEach(() => s.close());

  it("needs the PIN cookie; render token opens only the render page's GETs", async () => {
    expect((await s.req("GET", "/api/info")).body).toMatchObject({ pinRequired: true, authed: false });
    expect((await s.req("GET", "/api/shows")).status).toBe(401);
    expect((await s.req("POST", "/api/device/hello", {}, { "X-Device-Key": "7xk_bad" })).status).toBe(401);

    expect((await s.req("POST", "/api/session", { pin: "0000" })).status).toBe(401);
    const ok = await s.req("POST", "/api/session", { pin: "4321" });
    expect(ok.status).toBe(204);
    const cookie = ok.headers.get("set-cookie")!.split(";")[0]!;
    expect(ok.headers.get("set-cookie")).toContain("HttpOnly");
    const C = { cookie };
    expect((await s.req("GET", "/api/info", undefined, C)).body.authed).toBe(true);

    const show = (await s.req("POST", "/api/shows", { title: "Pin show" }, C)).body;
    const other = (await s.req("POST", "/api/shows", { title: "Other" }, C)).body;
    const t = s.studio.tokens.renderToken(show.id);

    expect((await s.req("GET", `/api/shows/${show.id}?t=${encodeURIComponent(t)}`)).status).toBe(200);
    expect((await s.req("GET", `/api/shows/${show.id}/control`, undefined, { [RENDER_TOKEN_HEADER]: t })).status).toBe(200);
    expect((await s.req("GET", `/api/devices`, undefined, { [RENDER_TOKEN_HEADER]: t })).status).toBe(200);
    expect((await s.req("GET", `/api/props`, undefined, { [RENDER_TOKEN_HEADER]: t })).status).toBe(200);
    // not for another show, not for writes, not for other routes
    expect((await s.req("GET", `/api/shows/${other.id}`, undefined, { [RENDER_TOKEN_HEADER]: t })).status).toBe(401);
    expect((await s.req("PATCH", `/api/shows/${show.id}?t=${encodeURIComponent(t)}`, { title: "Hacked" })).status).toBe(401);
    expect((await s.req("GET", `/api/destinations`, undefined, { [RENDER_TOKEN_HEADER]: t })).status).toBe(401);
    expect((await s.req("GET", `/api/shows`, undefined, { [RENDER_TOKEN_HEADER]: t })).status).toBe(401);
  });
});
