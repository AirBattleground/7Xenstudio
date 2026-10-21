/** Props: videos / images uploaded for scenes (intro loop, logo, image slots). Files in DATA_DIR/props, served with Range. */
import { open, rename, unlink } from "node:fs/promises";
import type { IncomingMessage, ServerResponse } from "node:http";
import path from "node:path";
import type { Prop } from "../shared/types.js";
import { HttpError, badRequest, imageType, notFound, sendFile, streamMultipart } from "./http.js";
import { newId, type Store, type StoredProp } from "./store.js";

export const MAX_VIDEO_BYTES = 500 * 1024 * 1024;
export const MAX_IMAGE_BYTES = 10 * 1024 * 1024;
const MAX_PROPS = 200;

const VIDEO_TYPES: Record<string, string> = { ".mp4": "video/mp4", ".m4v": "video/mp4", ".webm": "video/webm", ".mov": "video/quicktime" };
const IMAGE_EXT: Record<string, string> = { "image/png": ".png", "image/jpeg": ".jpg", "image/webp": ".webp", "image/gif": ".gif" };

const isVideo = (ct: string | null, filename: string | null) =>
  (!!ct && /^video\//i.test(ct)) || (!!filename && path.extname(filename).toLowerCase() in VIDEO_TYPES);

export class Props {
  constructor(private readonly store: Store) {}

  private toProp(p: StoredProp): Prop {
    return { id: p.id, name: p.name, kind: p.kind, sizeBytes: p.sizeBytes, url: `/api/props/${p.id}/file` };
  }

  list(): Prop[] {
    return [...this.store.doc.props].sort((a, b) => b.createdAt.localeCompare(a.createdAt)).map((p) => this.toProp(p));
  }

  get(id: string): StoredProp {
    const p = this.store.doc.props.find((x) => x.id === id);
    if (!p) throw notFound("Prop not found");
    return p;
  }

  async upload(req: IncomingMessage): Promise<Prop> {
    if (this.store.doc.props.length >= MAX_PROPS) throw new HttpError(409, "CONFLICT", `You can keep up to ${MAX_PROPS} props. Delete some first.`);
    const id = newId("p");
    const tmp = path.join(this.store.propsDir, `${id}.upload`);
    const up = await streamMultipart(req, {
      fileField: "file",
      destPath: tmp,
      limitFor: (ct, filename) => (isVideo(ct, filename) ? MAX_VIDEO_BYTES : MAX_IMAGE_BYTES),
    });
    const cleanup = () => unlink(tmp).catch(() => {});
    if (!up.file || up.file.size === 0) {
      await cleanup();
      throw badRequest("Choose a video or image file", { file: "Required" });
    }
    // sniff the first bytes: images by magic number, videos by type / extension
    const fh = await open(tmp, "r");
    const head = Buffer.alloc(16);
    await fh.read(head, 0, 16, 0);
    await fh.close();
    const img = imageType(head);
    let kind: "video" | "image";
    let mime: string;
    let ext: string;
    if (img) {
      if (up.file.size > MAX_IMAGE_BYTES) {
        await cleanup();
        throw new HttpError(413, "VALIDATION_ERROR", "Images can be up to 10 MB");
      }
      kind = "image";
      mime = img;
      ext = IMAGE_EXT[img]!;
    } else if (isVideo(up.file.contentType, up.file.filename)) {
      kind = "video";
      const e = path.extname(up.file.filename ?? "").toLowerCase();
      ext = e in VIDEO_TYPES ? e : up.file.contentType === "video/webm" ? ".webm" : up.file.contentType === "video/quicktime" ? ".mov" : ".mp4";
      mime = VIDEO_TYPES[ext]!;
    } else {
      await cleanup();
      throw badRequest("Only videos (MP4, WebM, MOV) or images (PNG, JPEG, WebP, GIF)", { file: "Unsupported file type" });
    }
    const file = `${id}${ext}`;
    await rename(tmp, path.join(this.store.propsDir, file));
    const name = (up.fields.name?.trim() || path.parse(up.file.filename ?? "").name || (kind === "video" ? "Video" : "Image")).slice(0, 60);
    const prop: StoredProp = { id, name, kind, sizeBytes: up.file.size, file, mime, createdAt: new Date().toISOString() };
    this.store.doc.props.push(prop);
    this.store.save();
    return this.toProp(prop);
  }

  send(req: IncomingMessage, res: ServerResponse, id: string) {
    const p = this.get(id);
    return sendFile(req, res, path.join(this.store.propsDir, p.file), { contentType: p.mime, cache: "private, max-age=86400", missing: "Prop file is missing" });
  }

  async remove(id: string) {
    const p = this.get(id);
    this.store.doc.props = this.store.doc.props.filter((x) => x.id !== id);
    this.store.save();
    await unlink(path.join(this.store.propsDir, p.file)).catch(() => {});
  }
}
