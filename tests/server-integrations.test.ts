import http from "node:http";
import type { AddressInfo } from "node:net";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { DEFAULT_HOST, parseConnectLink } from "../src/server/integrations/airbattleground/link.js";
import { startTestStudio } from "./server-helpers.js";

describe("AirBattleground link parsing", () => {
  const key = "sw_abcdefgh12345678";
  it.each([
    [`7xen-studio://connect?host=https://airbattleground.com&key=${key}`, { host: "https://airbattleground.com", key }],
    [`7xen-studio://connect?host=${encodeURIComponent("http://192.168.1.4:4000/")}&key=${key}`, { host: "http://192.168.1.4:4000", key }],
    [`https://staging.airbattleground.com/manager/studio?key=${key}`, { host: "https://staging.airbattleground.com", key }],
    [`  ${key}  `, { host: DEFAULT_HOST, key }],
    ["7xen-studio://connect?host=ftp://x&key=" + key, null],
    ["7xen-studio://connect?host=https://x.com&key=nope", null],
    ["hello", null],
  ])("%s", (input, want) => {
    expect(parseConnectLink(input)).toEqual(want);
  });
});

/** A fake AirBattleground studio-link API. */
function fakeAbg() {
  const calls: { method: string; path: string; key: string | undefined; body: string; contentType: string | undefined }[] = [];
  let stopNext = false;
  let down = false;
  const server = http.createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString("latin1");
      calls.push({ method: req.method!, path: req.url!, key: req.headers["x-studio-key"] as string | undefined, body, contentType: req.headers["content-type"] });
      const json = (status: number, b?: unknown) => {
        res.writeHead(status, { "content-type": "application/json" });
        res.end(b === undefined ? undefined : JSON.stringify(b));
      };
      if (req.headers["x-studio-key"] !== "sw_goodkey12345678") return json(401, { error: { code: "UNAUTHENTICATED", message: "Bad key" } });
      if (down && req.url === "/api/studio-link/broadcasts") return json(503, { error: { code: "INTERNAL", message: "Down for maintenance" } });
      if (req.url === "/api/studio-link/me") return json(200, { manager: { name: "Rohan" }, org: { name: "Night Owls" } });
      if (req.url === "/api/studio-link/matches") return json(200, { items: [{ id: "m1", title: "Match 1", subtitle: "Erangel", startsAt: "2026-10-21T14:30:00Z", status: "upcoming" }] });
      if (req.url === "/api/studio-link/outputs")
        return json(200, { livePage: true, siteYoutube: { channelTitle: "ABG Live" }, destinations: [{ id: "k1", name: "Org YouTube", kind: "YOUTUBE" }] });
      if (req.url === "/api/studio-link/broadcasts") return json(201, { id: "b1", targets: [{ id: "lp", name: "Live page", url: "rtmp://media.example/live/abc" }], watchUrl: "https://x/watch" });
      if (req.url === "/api/studio-link/broadcasts/b1/heartbeat") return json(200, { stop: stopNext });
      if (req.url === "/api/studio-link/broadcasts/b1/stop") return json(204);
      if (req.url === "/api/studio-link/matches/m1/screenshots") return json(201, { count: 1 });
      json(404, { error: { code: "NOT_FOUND", message: "nope" } });
    });
  });
  return {
    server,
    calls,
    setStop: (v: boolean) => (stopNext = v),
    setDown: (v: boolean) => (down = v),
  };
}

describe("AirBattleground integration through the studio API", () => {
  const abg = fakeAbg();
  let host = "";
  beforeAll(async () => {
    await new Promise<void>((r) => abg.server.listen(0, "127.0.0.1", r));
    host = `http://127.0.0.1:${(abg.server.address() as AddressInfo).port}`;
  });
  afterAll(() => new Promise<void>((r) => abg.server.close(() => r())));

  it("connect, events, outputs, broadcast with heartbeat-stop, capture, disconnect", async () => {
    const s = await startTestStudio();
    try {
      const list = (await s.req("GET", "/api/integrations")).body.items;
      expect(list).toEqual([{ id: "airbattleground", name: "AirBattleground", connected: false, account: null, host: null, error: null }]);

      const bad = await s.req("POST", "/api/integrations/airbattleground/connect", { link: `7xen-studio://connect?host=${host}&key=sw_wrongkey1234567` });
      expect(bad.status).toBe(502);
      expect(bad.body.error.code).toBe("INTEGRATION_KEY_INVALID");

      const ok = await s.req("POST", "/api/integrations/airbattleground/connect", { link: `7xen-studio://connect?host=${encodeURIComponent(host)}&key=sw_goodkey12345678` });
      expect(ok.body).toMatchObject({ connected: true, account: { name: "Rohan", org: "Night Owls" }, host });
      expect(s.studio.store.doc.integrations.airbattleground).toMatchObject({ key: "sw_goodkey12345678", host });

      expect((await s.req("GET", "/api/integrations/airbattleground/events")).body.items[0]).toMatchObject({ id: "m1", title: "Match 1", status: "upcoming" });
      expect((await s.req("GET", "/api/integrations/airbattleground/outputs")).body.items).toEqual([
        { id: "abg:live-page", name: "AirBattleground Live page", kind: "live-page", defaultOn: true },
        { id: "abg:youtube", name: "YouTube: ABG Live", kind: "youtube", defaultOn: false },
        { id: "abg:key:k1", name: "Org YouTube", kind: "rtmp", defaultOn: false },
      ]);

      const show = (await s.req("POST", "/api/shows", { title: "Linked show" })).body;
      await s.req("PATCH", `/api/shows/${show.id}`, {
        outputs: { record: false, destinationIds: [] },
        link: { integration: "airbattleground", eventId: "m1", eventTitle: "Match 1", outputIds: ["abg:live-page", "abg:key:k1"] },
      });
      const st = (await s.req("POST", `/api/shows/${show.id}/start`)).body;
      expect(st.integration).toMatchObject({ id: "airbattleground", broadcastId: "b1", watchUrl: "https://x/watch", error: null });
      const sent = abg.calls.find((c) => c.path === "/api/studio-link/broadcasts")!;
      expect(JSON.parse(sent.body)).toEqual({ matchId: "m1", title: "Linked show", livePage: true, siteYoutube: false, destinationIds: ["k1"] });
      expect(sent.key).toBe("sw_goodkey12345678");
      expect(s.pipeline.runs[0]!.opts.targets.map((t) => t.id)).toEqual(["preview", "int:airbattleground:lp"]);

      // the integration asks to stop on a heartbeat → the show ends and the broadcast is stopped
      abg.setStop(true);
      const rt = (s.studio.shows as any).runtimes.get(show.id);
      clearInterval(rt.heartbeat);
      const it = s.studio.integrations.get("airbattleground")!;
      expect(await it.heartbeat("b1", { state: "live", fps: 60, bitrateKbps: 6000 })).toEqual({ stop: true });
      await s.studio.shows.stop(show.id);
      expect(abg.calls.some((c) => c.path === "/api/studio-link/broadcasts/b1/stop")).toBe(true);
      expect(s.pipeline.runs[0]!.stopped).toBe(true);

      // fail soft: AirBattleground down at start → local outputs still go, status shows the error
      abg.setDown(true);
      await s.req("PATCH", `/api/shows/${show.id}`, { outputs: { record: true, destinationIds: [] } });
      const st2 = (await s.req("POST", `/api/shows/${show.id}/start`)).body;
      expect(st2.state).toBe("LIVE");
      expect(st2.integration.error).toContain("Down for maintenance");
      expect(st2.outputs.find((o: { id: string }) => o.id === "integration:airbattleground")).toMatchObject({ ok: false });
      expect(s.pipeline.runs[1]!.opts.targets.map((t) => t.id)).toEqual(["record", "preview"]);
      await s.req("POST", `/api/shows/${show.id}/stop`);
      abg.setDown(false);

      // capture → multipart files + kind
      const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(64, 9)]);
      const form = new FormData();
      form.append("file", new Blob([png], { type: "image/png" }), "still.png");
      form.append("kind", "RESULTS");
      const cap = await s.req("POST", "/api/integrations/airbattleground/events/m1/capture", form);
      expect(cap.body).toEqual({ ok: true });
      const shot = abg.calls.find((c) => c.path === "/api/studio-link/matches/m1/screenshots")!;
      expect(shot.contentType).toMatch(/^multipart\/form-data/);
      expect(shot.body).toContain('name="files"');
      expect(shot.body).toContain("RESULTS");

      expect((await s.req("DELETE", "/api/integrations/airbattleground")).status).toBe(204);
      expect((await s.req("GET", "/api/integrations")).body.items[0].connected).toBe(false);
      expect((await s.req("GET", "/api/integrations/airbattleground/events")).status).toBe(409);
    } finally {
      await s.close();
    }
  });
});
