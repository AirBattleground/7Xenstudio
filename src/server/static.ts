/** The web app build (WEB_DIST) with SPA fallback: index.html never cached, hashed /assets/* cached for a year. */
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import path from "node:path";
import type { IncomingMessage, ServerResponse } from "node:http";

const TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".webmanifest": "application/manifest+json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".gif": "image/gif",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".mp3": "audio/mpeg",
  ".mp4": "video/mp4",
  ".webm": "video/webm",
  ".wasm": "application/wasm",
  ".txt": "text/plain; charset=utf-8",
};

async function fileAt(p: string) {
  try {
    const s = await stat(p);
    return s.isFile() ? s : null;
  } catch {
    return null;
  }
}

export function makeStatic(root: string) {
  const base = path.resolve(root);
  return async (req: IncomingMessage, res: ServerResponse) => {
    if (req.method !== "GET" && req.method !== "HEAD") {
      res.writeHead(405, { Allow: "GET, HEAD" }).end();
      return;
    }
    let rel: string;
    try {
      rel = decodeURIComponent(new URL(req.url ?? "/", "http://studio").pathname);
    } catch {
      res.writeHead(400).end();
      return;
    }
    let file = path.resolve(base, "." + path.posix.normalize(rel));
    if (file !== base && !file.startsWith(base + path.sep)) file = path.join(base, "index.html");
    let s = rel.endsWith("/") ? null : await fileAt(file);
    let spa = false;
    if (!s) {
      // missing hashed asset → a real 404 (an HTML fallback would break the module loader in confusing ways)
      if (rel.startsWith("/assets/")) {
        res.writeHead(404, { "Content-Type": "text/plain" }).end("Not found");
        return;
      }
      file = path.join(base, "index.html");
      s = await fileAt(file);
      spa = true;
    }
    if (!s) {
      res.writeHead(503, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
      res.end(`<!doctype html><meta charset="utf-8"><title>7XEN Studio</title><body style="font-family:system-ui;padding:2rem"><h1>7XEN Studio is running</h1><p>The web app build is missing. In the studio-app folder run <code>pnpm build</code> (or set WEB_DIST), then reload.</p>`);
      return;
    }
    const isIndex = spa || path.basename(file) === "index.html";
    res.writeHead(200, {
      "Content-Type": TYPES[path.extname(file).toLowerCase()] ?? "application/octet-stream",
      "Content-Length": s.size,
      "Cache-Control": isIndex ? "no-cache" : rel.startsWith("/assets/") ? "public, max-age=31536000, immutable" : "public, max-age=3600",
      "X-Content-Type-Options": "nosniff",
    });
    if (req.method === "HEAD") {
      res.end();
      return;
    }
    createReadStream(file).on("error", () => res.destroy()).pipe(res);
  };
}
