/** "Record on this PC": the renderer writes fragmented MP4 into DATA_DIR/recordings; list, play (Range), download, delete. */
import { mkdir, readdir, stat, statfs, unlink } from "node:fs/promises";
import type { IncomingMessage, ServerResponse } from "node:http";
import { join } from "node:path";
import type { Recording, Recordings as RecordingsList } from "../shared/types.js";
import { HttpError, notFound, sendFile } from "./http.js";

const FILE_RE = /^[A-Za-z0-9_.-]{1,160}\.mp4$/;
/** a file written to within this long is treated as still recording */
export const ACTIVE_MS = 10_000;

/** 2026-10-21_19-05-12_evening-show_<showId>.mp4 → parts (best effort for hand-copied files) */
export function parseRecordingName(file: string): { title: string; showId: string | null } {
  const m = /^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_(.*)_([A-Za-z0-9]{8,40})\.mp4$/.exec(file);
  if (!m) return { title: file.replace(/\.mp4$/, ""), showId: null };
  const title = m[1]!.replace(/-/g, " ").trim();
  return { title: title ? title[0]!.toUpperCase() + title.slice(1) : "Show", showId: m[2]! };
}

export class Recordings {
  constructor(readonly dir: string) {}

  private path(file: string) {
    if (!FILE_RE.test(file)) throw notFound("Recording not found");
    return join(this.dir, file);
  }

  async list(now = Date.now()): Promise<RecordingsList> {
    await mkdir(this.dir, { recursive: true });
    const items: Recording[] = [];
    for (const file of await readdir(this.dir)) {
      if (!FILE_RE.test(file)) continue;
      const st = await stat(join(this.dir, file)).catch(() => null);
      if (!st?.isFile()) continue;
      items.push({
        file,
        ...parseRecordingName(file),
        sizeBytes: st.size,
        startedAt: st.birthtime.getTime() ? st.birthtime.toISOString() : st.ctime.toISOString(),
        updatedAt: st.mtime.toISOString(),
        recording: now - st.mtimeMs < ACTIVE_MS,
      });
    }
    items.sort((a, b) => b.file.localeCompare(a.file));
    const fs = await statfs(this.dir);
    return { items, disk: { freeBytes: fs.bavail * fs.bsize, totalBytes: fs.blocks * fs.bsize } };
  }

  send(req: IncomingMessage, res: ServerResponse, file: string, download: boolean) {
    return sendFile(req, res, this.path(file), { contentType: "video/mp4", downloadName: download ? file : undefined, missing: "Recording not found" });
  }

  async remove(file: string, now = Date.now()) {
    const p = this.path(file);
    const st = await stat(p).catch(() => null);
    if (!st?.isFile()) throw notFound("Recording not found");
    if (now - st.mtimeMs < ACTIVE_MS) throw new HttpError(409, "CONFLICT", "This show is still recording. End it first.");
    await unlink(p);
  }
}
