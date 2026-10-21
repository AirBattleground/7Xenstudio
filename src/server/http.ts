/** Small node:http helpers: the API error shape, JSON bodies, zod validation, multipart, Range file serving, rate limit. */
import { createReadStream, createWriteStream } from "node:fs";
import { stat, unlink } from "node:fs/promises";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { ZodTypeAny, z } from "zod";

export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly fields?: Record<string, string>,
  ) {
    super(message);
  }
}

export const notFound = (message = "Not found") => new HttpError(404, "NOT_FOUND", message);
export const conflict = (message: string) => new HttpError(409, "CONFLICT", message);
export const badRequest = (message: string, fields?: Record<string, string>) => new HttpError(400, "VALIDATION_ERROR", message, fields);

export function sendJson(res: ServerResponse, status: number, body: unknown, headers: Record<string, string | string[]> = {}) {
  const data = JSON.stringify(body);
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "Content-Length": Buffer.byteLength(data), ...headers });
  res.end(data);
}

export function noContent(res: ServerResponse, headers: Record<string, string | string[]> = {}) {
  res.writeHead(204, headers).end();
}

export function sendError(res: ServerResponse, err: unknown) {
  if (res.headersSent) {
    res.destroy();
    return;
  }
  if (err instanceof HttpError) {
    sendJson(res, err.status, { error: { code: err.code, message: err.message, ...(err.fields ? { fields: err.fields } : {}) } });
    return;
  }
  console.error("studio: unexpected error", err);
  sendJson(res, 500, { error: { code: "INTERNAL", message: "Something went wrong in the studio. Try again." } });
}

export function readBody(req: IncomingMessage, limit: number): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (c: Buffer) => {
      size += c.length;
      if (size > limit) {
        reject(new HttpError(413, "VALIDATION_ERROR", "That upload is too big"));
        req.resume();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

export async function readJson(req: IncomingMessage, limit = 256 * 1024): Promise<unknown> {
  const buf = await readBody(req, limit);
  if (!buf.length) return {};
  try {
    return JSON.parse(buf.toString("utf8"));
  } catch {
    throw badRequest("The request body isn't valid JSON");
  }
}

/** 400 VALIDATION_ERROR with per-field messages. */
export function parse<S extends ZodTypeAny>(schema: S, data: unknown): z.output<S> {
  const r = schema.safeParse(data ?? {});
  if (r.success) return r.data;
  const fields: Record<string, string> = {};
  for (const issue of r.error.issues) {
    const key = issue.path.join(".") || "_";
    if (!(key in fields)) fields[key] = issue.message;
  }
  const first = Object.values(fields)[0];
  throw badRequest(Object.keys(fields).length === 1 && first ? `Please check your input: ${first}` : "Please check the highlighted fields", fields);
}

/** PNG / JPEG / WebP / GIF by magic bytes */
export function imageType(b: Buffer): "image/png" | "image/jpeg" | "image/webp" | "image/gif" | null {
  if (b.length < 12) return null;
  if (b[0] === 0x89 && b.subarray(1, 4).toString("latin1") === "PNG") return "image/png";
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  if (b.subarray(0, 4).toString("latin1") === "RIFF" && b.subarray(8, 12).toString("latin1") === "WEBP") return "image/webp";
  if (b.subarray(0, 4).toString("latin1") === "GIF8") return "image/gif";
  return null;
}

export const header = (req: IncomingMessage, name: string) => {
  const v = req.headers[name.toLowerCase()];
  return Array.isArray(v) ? v[0] : v;
};

export function boundaryOf(contentType: string | undefined): string | null {
  if (!/^multipart\/form-data/i.test(contentType ?? "")) return null;
  const m = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType ?? "");
  return m?.[1] ?? m?.[2]?.trim() ?? null;
}

export interface Part {
  name: string;
  filename: string | null;
  contentType: string | null;
  data: Buffer;
}

/** All parts of a (small, buffered) multipart/form-data body. */
export function multipartParts(body: Buffer, contentType: string | undefined): Part[] {
  const boundary = boundaryOf(contentType);
  if (!boundary) return [];
  const delim = Buffer.from(`--${boundary}`);
  const out: Part[] = [];
  let pos = body.indexOf(delim);
  while (pos >= 0) {
    const start = pos + delim.length;
    if (body.subarray(start, start + 2).toString() === "--") break;
    const headerEnd = body.indexOf("\r\n\r\n", start);
    if (headerEnd < 0) break;
    const headers = body.subarray(start, headerEnd).toString("utf8");
    const next = body.indexOf(delim, headerEnd + 4);
    if (next < 0) break;
    const name = /name="([^"]*)"/i.exec(headers)?.[1];
    if (name !== undefined) {
      out.push({
        name,
        filename: /filename="([^"]*)"/i.exec(headers)?.[1] ?? null,
        contentType: /content-type:\s*([^\r\n;]+)/i.exec(headers)?.[1]?.trim() ?? null,
        data: body.subarray(headerEnd + 4, next - 2),
      });
    }
    pos = next;
  }
  return out;
}

export interface StreamedUpload {
  fields: Record<string, string>;
  file: { name: string; filename: string | null; contentType: string | null; path: string; size: number } | null;
}

/**
 * Stream a multipart/form-data upload: the first part named `fileField` goes straight to `destPath` (never buffered),
 * the other (small) fields are collected. `limitFor(contentType)` sets the file size limit once the part's headers
 * are known. On any error the partial file is removed.
 */
export function streamMultipart(
  req: IncomingMessage,
  opts: { fileField: string; destPath: string; limitFor: (contentType: string | null, filename: string | null) => number; fieldLimit?: number },
): Promise<StreamedUpload> {
  const boundary = boundaryOf(header(req, "content-type"));
  if (!boundary) return Promise.reject(badRequest("Send the file as multipart/form-data"));
  const delim = Buffer.from(`\r\n--${boundary}`);
  const fieldLimit = opts.fieldLimit ?? 16 * 1024;

  return new Promise<StreamedUpload>((resolve, reject) => {
    const fields: Record<string, string> = {};
    let file: StreamedUpload["file"] = null;
    // prepend CRLF so the first delimiter matches like the others
    let buf: Buffer = Buffer.from("\r\n");
    let state: "preamble" | "headers" | "body" | "done" = "preamble";
    let part: { name: string; filename: string | null; contentType: string | null; isFile: boolean; chunks: Buffer[]; size: number; limit: number } | null = null;
    let out: ReturnType<typeof createWriteStream> | null = null;
    let failed = false;
    let pendingWrites = Promise.resolve();

    const fail = (err: unknown) => {
      if (failed) return;
      failed = true;
      req.unpipe();
      req.resume();
      const finish = () => {
        unlink(opts.destPath).catch(() => {});
        reject(err);
      };
      if (out) out.destroy();
      finish();
    };

    const writeFile = (chunk: Buffer) => {
      if (!out || !part || !chunk.length) return;
      part.size += chunk.length;
      if (part.size > part.limit) return fail(new HttpError(413, "VALIDATION_ERROR", `That file is too big (the limit is ${Math.round(part.limit / 1024 / 1024)} MB)`));
      const o = out;
      if (!o.write(chunk)) {
        req.pause();
        o.once("drain", () => {
          if (!failed) req.resume();
        });
      }
    };

    const pump = () => {
      for (;;) {
        if (failed) return;
        if (state === "preamble") {
          const i = buf.indexOf(delim);
          if (i < 0) {
            buf = buf.subarray(Math.max(0, buf.length - delim.length));
            return;
          }
          buf = buf.subarray(i + delim.length);
          state = "headers";
        } else if (state === "headers") {
          if (buf.length < 2) return;
          if (buf.subarray(0, 2).toString() === "--") {
            state = "done";
            return;
          }
          const end = buf.indexOf("\r\n\r\n");
          if (end < 0) {
            if (buf.length > 16 * 1024) return fail(badRequest("Malformed upload"));
            return;
          }
          const headers = buf.subarray(0, end).toString("utf8");
          buf = buf.subarray(end + 4);
          const name = /name="([^"]*)"/i.exec(headers)?.[1] ?? "";
          const filename = /filename="([^"]*)"/i.exec(headers)?.[1] ?? null;
          const contentType = /content-type:\s*([^\r\n;]+)/i.exec(headers)?.[1]?.trim() ?? null;
          const isFile = name === opts.fileField && !file;
          part = { name, filename, contentType, isFile, chunks: [], size: 0, limit: isFile ? opts.limitFor(contentType, filename) : fieldLimit };
          if (isFile) {
            out = createWriteStream(opts.destPath);
            out.on("error", fail);
            file = { name, filename, contentType, path: opts.destPath, size: 0 };
          }
          state = "body";
        } else if (state === "body") {
          const i = buf.indexOf(delim);
          const p = part!;
          if (i < 0) {
            // keep a tail that could be the start of the delimiter
            const keep = Math.min(buf.length, delim.length);
            const chunk = buf.subarray(0, buf.length - keep);
            buf = buf.subarray(buf.length - keep);
            if (p.isFile) writeFile(Buffer.from(chunk));
            else {
              p.size += chunk.length;
              if (p.size > p.limit) return fail(badRequest("A form field is too long"));
              p.chunks.push(Buffer.from(chunk));
            }
            return;
          }
          const chunk = buf.subarray(0, i);
          buf = buf.subarray(i + delim.length);
          if (p.isFile) {
            writeFile(Buffer.from(chunk));
            if (failed) return;
            file!.size = p.size;
            const o = out!;
            out = null;
            pendingWrites = new Promise<void>((res, rej) => {
              o.end(() => res());
              o.on("error", rej);
            });
            // a paused request (backpressure on the last write) would never resume: drain doesn't fire after end()
            req.resume();
          } else {
            p.size += chunk.length;
            if (p.size > p.limit) return fail(badRequest("A form field is too long"));
            p.chunks.push(Buffer.from(chunk));
            if (p.name) fields[p.name] = Buffer.concat(p.chunks).toString("utf8");
          }
          part = null;
          state = "headers";
        } else return;
      }
    };

    req.on("data", (c: Buffer) => {
      if (failed) return;
      buf = buf.length ? Buffer.concat([buf, c]) : c;
      pump();
    });
    req.on("error", fail);
    req.on("aborted", () => fail(badRequest("The upload was interrupted")));
    req.on("end", () => {
      if (failed) return;
      if (state !== "done") return fail(badRequest("The upload was interrupted"));
      pendingWrites.then(() => resolve({ fields, file }), fail);
    });
  });
}

/** Stream a file honouring a single Range ("bytes=a-b"), so <video> can seek. */
export async function sendFile(
  req: IncomingMessage,
  res: ServerResponse,
  file: string,
  opts: { contentType: string; cache?: string; downloadName?: string; missing?: string },
) {
  const st = await stat(file).catch(() => null);
  if (!st?.isFile()) throw notFound(opts.missing);
  const headers: Record<string, string | number> = {
    "Content-Type": opts.contentType,
    "Accept-Ranges": "bytes",
    "Cache-Control": opts.cache ?? "no-store",
    "X-Content-Type-Options": "nosniff",
    ...(opts.downloadName ? { "Content-Disposition": `attachment; filename="${opts.downloadName.replace(/["\\\r\n]/g, "")}"` } : {}),
  };
  const range = /^bytes=(\d*)-(\d*)$/.exec(String(req.headers.range ?? "").trim());
  let start = 0;
  let end = st.size - 1;
  if (range && (range[1] || range[2])) {
    if (range[1]) {
      start = Number(range[1]);
      if (range[2]) end = Math.min(end, Number(range[2]));
    } else start = Math.max(0, st.size - Number(range[2]));
    if (start > end || start >= st.size) {
      res.writeHead(416, { "Content-Range": `bytes */${st.size}` }).end();
      return;
    }
    res.writeHead(206, { ...headers, "Content-Range": `bytes ${start}-${end}/${st.size}`, "Content-Length": end - start + 1 });
  } else res.writeHead(200, { ...headers, "Content-Length": st.size });
  if (req.method === "HEAD" || st.size === 0) return void res.end();
  await new Promise<void>((resolve) => {
    const s = createReadStream(file, { start, end });
    s.on("error", () => {
      res.destroy();
      resolve();
    });
    s.on("end", resolve);
    res.on("close", () => {
      s.destroy();
      resolve();
    });
    s.pipe(res);
  });
}

/** Fixed-window limiter per key (stops key / PIN guessing). */
export function rateLimiter(limit: number, windowMs: number, now: () => number = Date.now) {
  const hits = new Map<string, { start: number; count: number }>();
  return (key: string): boolean => {
    const t = now();
    if (hits.size > 10_000) hits.clear();
    const h = hits.get(key);
    if (!h || t - h.start >= windowMs) {
      hits.set(key, { start: t, count: 1 });
      return true;
    }
    h.count++;
    return h.count <= limit;
  };
}

export const remoteIp = (req: IncomingMessage) => req.socket.remoteAddress ?? "";
export const isLoopback = (ip: string | undefined) => !!ip && (ip === "::1" || ip.startsWith("127.") || ip.startsWith("::ffff:127."));

export function parseCookies(h: string | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  for (const part of (h ?? "").split(";")) {
    const i = part.indexOf("=");
    if (i <= 0) continue;
    const k = part.slice(0, i).trim();
    try {
      out[k] = decodeURIComponent(part.slice(i + 1).trim());
    } catch {
      /* ignore a broken cookie */
    }
  }
  return out;
}
