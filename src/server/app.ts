/**
 * The studio's HTTP server (one port, default 4400):
 *   /api/device/*          phone device API (7XEN Stream app, X-Device-Key)
 *   /internal/media/auth   MediaMTX auth hook (127.0.0.1 only)
 *   /api/*                 the studio API (PIN cookie when STUDIO_PIN is set; render token for the renderer's GETs)
 *   everything else        the web app build (SPA)
 */
import { readFileSync } from "node:fs";
import type { IncomingMessage, RequestListener, ServerResponse } from "node:http";
import path from "node:path";
import { Readable } from "node:stream";
import type { ReadableStream as WebReadableStream } from "node:stream/web";
import {
  CAPTURE_KINDS,
  DEVICE_KEY_HEADER,
  RENDER_TOKEN_HEADER,
  RENDER_TOKEN_PARAM,
  connectIntegrationSchema,
  controlSchema,
  createShowSchema,
  destinationSchema,
  destinationUpdateSchema,
  deviceHeartbeatSchema,
  deviceHelloSchema,
  deviceNameSchema,
  deviceStreamStartSchema,
  pairUrl,
  pinSchema,
  settingsSchema,
  updateShowSchema,
  type CaptureKind,
  type Destination,
  type StudioInfo,
} from "../shared/types.js";
import { APP_DIR, type Config } from "./config.js";
import { Devices } from "./devices.js";
import {
  HttpError,
  badRequest,
  conflict,
  header,
  imageType,
  isLoopback,
  multipartParts,
  noContent,
  notFound,
  parse,
  parseCookies,
  rateLimiter,
  readBody,
  readJson,
  remoteIp,
  sendError,
  sendJson,
} from "./http.js";
import { IntegrationRegistry, type IntegrationFactory } from "./integrations/registry.js";
import { MediaClient, authorizeMedia, devicePath, showPath, type Media, type MediaAuthRequest } from "./media.js";
import type { StartPipeline } from "./pipeline/types.js";
import { Props } from "./props.js";
import { Recordings } from "./recordings.js";
import { Shows } from "./shows.js";
import { makeStatic } from "./static.js";
import { Store, newId, type StoredDestination } from "./store.js";
import { SESSION_COOKIE, Tokens } from "./tokens.js";

const HLS_FILE_RE = /^[A-Za-z0-9_.-]{1,80}\.(m3u8|mp4|m4s|ts)$/;
const ID_RE = /^[A-Za-z0-9]{8,40}$/;
const MAX_SNAPSHOT_BYTES = 15 * 1024 * 1024;
const MAX_CAPTURE_BYTES = 15 * 1024 * 1024;

export const VERSION = (() => {
  try {
    return (JSON.parse(readFileSync(path.join(APP_DIR, "package.json"), "utf8")) as { version?: string }).version ?? "0.0.0";
  } catch {
    return "0.0.0";
  }
})();

export interface StudioDeps {
  startPipeline: StartPipeline;
  media?: Media;
  integrations?: IntegrationFactory[];
  /** the encoder the pipeline detected (StudioInfo.encoder before the first show) */
  detectedEncoder?: () => string | null;
  log?: (msg: string) => void;
}

export interface Studio {
  handler: RequestListener;
  store: Store;
  tokens: Tokens;
  devices: Devices;
  shows: Shows;
  integrations: IntegrationRegistry;
  info(authed: boolean): StudioInfo;
}

export function createStudio(cfg: Config, deps: StudioDeps): Studio {
  const log = deps.log ?? ((m: string) => console.log(`${new Date().toISOString()} ${m}`));
  const store = new Store(cfg.dataDir);
  const tokens = new Tokens(store.secret);
  const media = deps.media ?? new MediaClient(cfg.mediaHlsUrl, cfg.mediaApiUrl, tokens);
  const studioName = () => store.doc.settings.name ?? cfg.studioName;
  const devices = new Devices({ store, tokens, media, studioName, lanHost: new URL(cfg.lanUrl).hostname, rtmpPort: cfg.mediaRtmpPort });
  const integrations = new IntegrationRegistry(
    (id) => ({ state: <T,>() => store.integrationState<T>(id), setState: (v) => store.setIntegrationState(id, v) }),
    deps.integrations,
  );
  const shows = new Shows({
    store,
    integrations,
    startPipeline: deps.startPipeline,
    renderUrl: (id) => `http://127.0.0.1:${cfg.port}/render/${id}?${RENDER_TOKEN_PARAM}=${encodeURIComponent(tokens.renderToken(id))}`,
    previewUrl: (id) => `rtmp://127.0.0.1:${cfg.mediaRtmpPort}/${showPath(id)}`,
    ffmpegPath: cfg.ffmpegPath,
    chromePath: cfg.chromePath,
    encoder: cfg.encoder,
    log,
  });
  const props = new Props(store);
  const recordings = new Recordings(store.recordingsDir);
  const serveStatic = makeStatic(cfg.webDist);
  const deviceLimit = rateLimiter(240, 60_000);
  const pinLimit = rateLimiter(10, 60_000);

  const info = (authed: boolean): StudioInfo => ({
    name: studioName(),
    lanUrl: cfg.lanUrl,
    version: VERSION,
    mediaRtmp: `rtmp://${new URL(cfg.lanUrl).hostname}:${cfg.mediaRtmpPort}/live`,
    encoder: shows.lastEncoder ?? deps.detectedEncoder?.() ?? cfg.encoder,
    pinRequired: !!cfg.pin,
    authed,
  });

  const hasSession = (req: IncomingMessage) => !cfg.pin || tokens.verifySession(cfg.pin, parseCookies(header(req, "cookie"))[SESSION_COOKIE]);

  /** GETs the render page makes, allowed with a render token for show `sid` */
  function renderAllowed(seg: string[], sid: string): boolean {
    const [a, b, c] = seg;
    if (a === "shows") return b === sid && (seg.length === 2 || (seg.length === 3 && (c === "control" || c === "status")));
    if (a === "devices") return seg.length === 1 || (seg.length === 4 && c === "live");
    if (a === "props") return seg.length === 1 || (seg.length === 3 && c === "file");
    if (a === "info") return true;
    return false;
  }

  function requireAuth(req: IncomingMessage, seg: string[], search: URLSearchParams) {
    if (hasSession(req)) return;
    const m = req.method ?? "GET";
    if (m === "GET" || m === "HEAD") {
      const sid = tokens.verifyRenderToken(search.get(RENDER_TOKEN_PARAM) ?? header(req, RENDER_TOKEN_HEADER));
      if (sid && renderAllowed(seg, sid)) return;
    }
    throw new HttpError(401, "UNAUTHENTICATED", "Enter the studio PIN to continue.");
  }

  // ---------------------------------------------------------------- device API

  async function deviceApi(req: IncomingMessage, res: ServerResponse, sub: string) {
    if (req.method !== "POST") throw notFound();
    if (!deviceLimit(remoteIp(req))) throw new HttpError(429, "RATE_LIMITED", "Too many requests from this device. Wait a minute and try again.");
    const dev = devices.fromKey(header(req, DEVICE_KEY_HEADER));
    const snap = /^snapshots\/([A-Za-z0-9-]{1,80})$/.exec(sub);
    if (snap) {
      const body = await readBody(req, MAX_SNAPSHOT_BYTES + 64 * 1024);
      const ct = header(req, "content-type");
      const img = /^multipart\/form-data/i.test(ct ?? "") ? (multipartParts(body, ct).find((p) => p.name === "image" || p.name === "file")?.data ?? null) : body;
      if (!img || !img.length) throw badRequest("Send the screenshot as the 'image' field", { image: "Required" });
      if (!imageType(img)) throw badRequest("Only PNG, JPEG or WebP images", { image: "Only PNG, JPEG or WebP images" });
      if (!devices.fulfilSnapshot(dev.id, snap[1]!, Buffer.from(img))) throw notFound("That capture request has expired");
      return noContent(res);
    }
    const body = await readJson(req);
    switch (sub) {
      case "hello":
        return sendJson(res, 200, devices.hello(dev, parse(deviceHelloSchema, body)));
      case "heartbeat":
        return sendJson(res, 200, devices.heartbeat(dev, parse(deviceHeartbeatSchema, body)));
      case "stream/start":
        parse(deviceStreamStartSchema, body);
        return sendJson(res, 200, devices.streamStart(dev));
      case "stream/stop":
        devices.streamStop(dev);
        return noContent(res);
      default:
        throw notFound();
    }
  }

  // ---------------------------------------------------------------- HLS proxy

  async function hlsProxy(res: ServerResponse, mediaPath: string, file: string, search: string, missing: string) {
    if (!HLS_FILE_RE.test(file)) throw notFound();
    // never forward the render token / anything else to MediaMTX except its own params
    const q = new URLSearchParams(search);
    q.delete(RENDER_TOKEN_PARAM);
    const qs = q.toString();
    const abort = new AbortController();
    res.on("close", () => abort.abort());
    const up = await media.fetchHls(mediaPath, file, qs ? `?${qs}` : "", abort.signal);
    if (!up || !up.ok || !up.body) throw notFound(missing);
    res.writeHead(up.status, {
      "Content-Type": up.headers.get("content-type") ?? "application/octet-stream",
      "Cache-Control": file.endsWith(".m3u8") ? "no-store" : "private, max-age=60",
      "X-Content-Type-Options": "nosniff",
      ...(up.headers.get("content-length") ? { "Content-Length": up.headers.get("content-length")! } : {}),
    });
    await new Promise<void>((resolve) => {
      const body = Readable.fromWeb(up.body as WebReadableStream);
      body.on("error", () => {
        res.destroy();
        resolve();
      });
      body.on("end", resolve);
      res.on("close", () => {
        body.destroy();
        resolve();
      });
      body.pipe(res);
    });
  }

  // ---------------------------------------------------------------- studio API

  const toDestination = (d: StoredDestination): Destination => ({ id: d.id, name: d.name, kind: d.kind, url: d.url, keyHint: d.streamKey.slice(-4) });
  const destination = (id: string) => {
    const d = store.doc.destinations.find((x) => x.id === id);
    if (!d) throw notFound("Stream key not found");
    return d;
  };

  async function api(req: IncomingMessage, res: ServerResponse, seg: string[], search: URLSearchParams) {
    const m = req.method ?? "GET";
    const [a, id, sub, rest] = seg;

    if (a === "info" && seg.length === 1 && m === "GET") return sendJson(res, 200, info(hasSession(req)));
    if (a === "session" && seg.length === 1) {
      if (m === "POST") {
        if (!pinLimit(remoteIp(req))) throw new HttpError(429, "RATE_LIMITED", "Too many tries. Wait a minute and try again.");
        const { pin } = parse(pinSchema, await readJson(req));
        if (!cfg.pin) return noContent(res);
        if (pin !== cfg.pin) throw new HttpError(401, "PIN_INVALID", "That PIN isn't right.", { pin: "Wrong PIN" });
        const c = tokens.sessionCookie(cfg.pin);
        return noContent(res, { "Set-Cookie": `${SESSION_COOKIE}=${c.value}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${c.maxAgeSec}` });
      }
      if (m === "DELETE") return noContent(res, { "Set-Cookie": `${SESSION_COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0` });
      throw notFound();
    }

    requireAuth(req, seg, search);

    switch (a) {
      case "settings": {
        if (m !== "PATCH" || seg.length !== 1) break;
        const input = parse(settingsSchema, await readJson(req));
        if (input.name !== undefined) {
          store.doc.settings.name = input.name;
          store.save();
        }
        return sendJson(res, 200, info(true));
      }

      case "devices": {
        if (!id) {
          if (m === "GET") return sendJson(res, 200, { items: await devices.rows() });
          if (m === "POST") {
            const { name } = parse(deviceNameSchema, await readJson(req));
            const { device, key } = devices.create(name);
            return sendJson(res, 201, { device: await devices.row(device), key, pairUrl: pairUrl(cfg.lanUrl, key, studioName()) });
          }
          break;
        }
        const dev = store.device(id);
        if (!dev) throw notFound("Phone not found");
        if (seg.length === 2) {
          if (m === "GET") return sendJson(res, 200, await devices.row(dev));
          if (m === "PATCH") {
            const { name } = parse(deviceNameSchema, await readJson(req));
            return sendJson(res, 200, await devices.row(devices.rename(id, name)));
          }
          if (m === "DELETE") {
            await devices.remove(id);
            return noContent(res);
          }
          break;
        }
        if (sub === "live" && seg.length === 4 && (m === "GET" || m === "HEAD")) return hlsProxy(res, devicePath(id), rest!, search.toString(), "The phone isn't streaming right now");
        if (sub === "snapshot.png" && seg.length === 3 && m === "GET") {
          const png = await devices.requestSnapshot(id);
          if (!png) throw new HttpError(504, "SNAPSHOT_TIMEOUT", "The phone didn't send a screenshot. Is the 7XEN Stream app open and streaming?");
          res.writeHead(200, { "Content-Type": imageType(png) ?? "image/png", "Cache-Control": "no-store", "Content-Length": png.length }).end(png);
          return;
        }
        break;
      }

      case "destinations": {
        if (!id) {
          if (m === "GET") return sendJson(res, 200, { items: store.doc.destinations.map(toDestination) });
          if (m === "POST") {
            const input = parse(destinationSchema, await readJson(req));
            if (store.doc.destinations.length >= 30) throw conflict("You can keep up to 30 stream keys. Remove one first.");
            const d: StoredDestination = { id: newId("k"), name: input.name, kind: input.kind, url: input.url, streamKey: input.streamKey, createdAt: new Date().toISOString() };
            store.doc.destinations.push(d);
            store.save();
            return sendJson(res, 201, toDestination(d));
          }
          break;
        }
        if (seg.length !== 2) break;
        const d = destination(id);
        if (m === "GET") return sendJson(res, 200, toDestination(d));
        if (m === "PATCH") {
          const input = parse(destinationUpdateSchema, await readJson(req));
          if (input.name !== undefined) d.name = input.name;
          if (input.kind !== undefined) d.kind = input.kind;
          if (input.url !== undefined) d.url = input.url;
          if (input.streamKey !== undefined) d.streamKey = input.streamKey;
          store.save();
          return sendJson(res, 200, toDestination(d));
        }
        if (m === "DELETE") {
          const live = shows.liveShow();
          if (live?.outputs.destinationIds.includes(id)) throw conflict("This stream key is in use by the live show. End the show first.");
          store.doc.destinations = store.doc.destinations.filter((x) => x.id !== id);
          store.save();
          shows.forgetDestination(id);
          return noContent(res);
        }
        break;
      }

      case "shows": {
        if (!id) {
          if (m === "GET") return sendJson(res, 200, { items: shows.list() });
          if (m === "POST") return sendJson(res, 201, shows.create(parse(createShowSchema, await readJson(req)).title));
          break;
        }
        if (seg.length === 2) {
          if (m === "GET") return sendJson(res, 200, shows.get(id));
          if (m === "PATCH") return sendJson(res, 200, shows.update(id, parse(updateShowSchema, await readJson(req, 1024 * 1024))));
          if (m === "DELETE") {
            shows.remove(id);
            return noContent(res);
          }
          break;
        }
        if (sub === "control" && seg.length === 3) {
          if (m === "GET") {
            const raw = search.get("since");
            const since = raw !== null && /^\d+$/.test(raw) ? Number(raw) : null;
            const abort = new AbortController();
            res.on("close", () => abort.abort());
            return sendJson(res, 200, await shows.waitControl(id, since, abort.signal));
          }
          if (m === "PATCH") return sendJson(res, 200, shows.setControl(id, parse(controlSchema, await readJson(req))));
          break;
        }
        if (seg.length === 3 && m === "POST" && sub === "start") return sendJson(res, 200, await shows.start(id));
        if (seg.length === 3 && m === "POST" && sub === "stop") return sendJson(res, 200, await shows.stop(id));
        if (seg.length === 3 && m === "GET" && sub === "status") return sendJson(res, 200, shows.status(id));
        if (sub === "live" && seg.length === 4 && (m === "GET" || m === "HEAD")) {
          if (!ID_RE.test(id)) throw notFound();
          shows.get(id);
          return hlsProxy(res, showPath(id), rest!, search.toString(), "The show isn't live right now");
        }
        break;
      }

      case "props": {
        if (!id) {
          if (m === "GET") return sendJson(res, 200, { items: props.list() });
          if (m === "POST") return sendJson(res, 201, await props.upload(req));
          break;
        }
        if (seg.length === 2 && m === "DELETE") {
          await props.remove(id);
          return noContent(res);
        }
        if (seg.length === 3 && sub === "file" && (m === "GET" || m === "HEAD")) return props.send(req, res, id);
        break;
      }

      case "recordings": {
        if (!id && m === "GET") return sendJson(res, 200, await recordings.list());
        if (id && seg.length === 2 && (m === "GET" || m === "HEAD")) return recordings.send(req, res, id, search.has("download") && search.get("download") !== "0");
        if (id && seg.length === 2 && m === "DELETE") {
          await recordings.remove(id);
          return noContent(res);
        }
        break;
      }

      case "integrations": {
        if (!id) {
          if (m === "GET") return sendJson(res, 200, { items: integrations.items.map((i) => i.info()) });
          break;
        }
        const it = integrations.get(id);
        if (!it) throw notFound("That connection isn't available");
        if (seg.length === 2 && m === "DELETE") {
          await it.disconnect();
          return noContent(res);
        }
        if (seg.length === 3 && sub === "connect" && m === "POST") return sendJson(res, 200, await it.connect(parse(connectIntegrationSchema, await readJson(req)).link));
        if (seg.length === 3 && sub === "events" && m === "GET") return sendJson(res, 200, { items: await it.events() });
        if (seg.length === 3 && sub === "outputs" && m === "GET") return sendJson(res, 200, { items: await it.outputs() });
        if (seg.length === 5 && sub === "events" && seg[4] === "capture" && m === "POST") {
          const body = await readBody(req, MAX_CAPTURE_BYTES + 64 * 1024);
          const parts = multipartParts(body, header(req, "content-type"));
          const file = parts.find((p) => p.name === "file" || p.name === "files")?.data;
          const kind = parts.find((p) => p.name === "kind")?.data.toString("utf8").trim();
          if (!file?.length || !imageType(file)) throw badRequest("Send the still as a PNG 'file'", { file: "Required" });
          if (!kind || !(CAPTURE_KINDS as readonly string[]).includes(kind)) throw badRequest("Pick what this capture is", { kind: "Unknown kind" });
          await it.capture(rest!, kind as CaptureKind, Buffer.from(file));
          return sendJson(res, 200, { ok: true });
        }
        break;
      }
    }
    throw notFound();
  }

  const handler: RequestListener = (req, res) => {
    const url = req.url ?? "/";
    const q = url.indexOf("?");
    const pathname = q < 0 ? url : url.slice(0, q);
    const search = new URLSearchParams(q < 0 ? "" : url.slice(q + 1));
    const run = async () => {
      if (pathname.startsWith("/api/device/")) return deviceApi(req, res, pathname.slice("/api/device/".length).replace(/\/+$/, ""));
      if (pathname === "/internal/media/auth") {
        if (req.method !== "POST" || !isLoopback(remoteIp(req))) throw notFound();
        const body = (await readJson(req).catch(() => ({}))) as MediaAuthRequest;
        const ok = authorizeMedia(body, { tokens, deviceKeyHash: (id) => store.device(id)?.keyHash });
        res.writeHead(ok ? 200 : 401).end();
        return;
      }
      if (pathname.startsWith("/internal/")) throw notFound();
      if (pathname === "/api" || pathname.startsWith("/api/")) {
        let seg: string[];
        try {
          seg = pathname.slice(5).replace(/\/+$/, "").split("/").filter(Boolean).map(decodeURIComponent);
        } catch {
          throw notFound();
        }
        return api(req, res, seg, search);
      }
      return serveStatic(req, res);
    };
    run().catch((err) => sendError(res, err));
  };

  return { handler, store, tokens, devices, shows, integrations, info };
}
