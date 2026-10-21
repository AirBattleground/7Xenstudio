/**
 * The server <-> pipeline (renderer) interface. The server owns this file; the pipeline implements
 * `startPipeline` in src/server/pipeline/index.ts.
 *
 * Contract:
 * - The pipeline opens `renderUrl` in headless Chrome, pipes the WebM chunks into ffmpeg and tees the
 *   encoded H.264 to every target. Chrome + ffmpeg always (re)start together, with backoff on failure.
 * - Record targets: `url` is a DIRECTORY (data/recordings). The pipeline names a new file per (re)start:
 *   `<YYYY-MM-DD_HH-mm-ss>_<slug>_<showId>.mp4` (local time; use `recordingFileName()` below), fragmented MP4.
 * - rtmp / preview targets: `url` is a full RTMP(S) URL (already joined with the stream key).
 * - `onStatus` is called whenever anything changes (at least every few seconds while running).
 * - `onExit` is called ONCE when the pipeline gives up for good (not on internal restarts, and not after stop()).
 */
export type PipelineTargetKind = "record" | "rtmp" | "preview";

export interface PipelineTarget {
  id: string;
  name: string;
  kind: PipelineTargetKind;
  /** record: directory to write into; rtmp/preview: full URL */
  url: string;
}

export interface PipelineOutputStatus {
  id: string;
  ok: boolean;
  error: string | null;
}

export interface PipelineStatus {
  state: "starting" | "live" | "error";
  /** frames per second ffmpeg is encoding */
  fps: number | null;
  /** ffmpeg encoder in use, e.g. "h264_nvenc" or "libx264" */
  encoder: string | null;
  bitrateKbps: number | null;
  error: string | null;
  outputs: PipelineOutputStatus[];
  /** basename of the recording file currently written (null when not recording) */
  recordingFile: string | null;
  /** how many times Chrome + ffmpeg were restarted */
  restarts: number;
}

export interface PipelineOptions {
  showId: string;
  title: string;
  /** url-safe slug of the title, for recording file names */
  slug: string;
  renderUrl: string;
  fps: 30 | 60;
  videoKbps: number;
  targets: PipelineTarget[];
  /** FFMPEG_PATH / CHROME_PATH / ENCODER from the env (null = auto) */
  ffmpegPath: string | null;
  chromePath: string | null;
  encoder: string | null;
  onStatus(status: PipelineStatus): void;
  onExit(reason: string): void;
}

export interface Pipeline {
  stop(): Promise<void>;
  status(): PipelineStatus;
}

export type StartPipeline = (opts: PipelineOptions) => Pipeline;

const pad = (n: number) => String(n).padStart(2, "0");
/** `<YYYY-MM-DD_HH-mm-ss>_<slug>_<showId>.mp4` in local time */
export function recordingFileName(slug: string, showId: string, at = new Date()): string {
  const d = `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())}_${pad(at.getHours())}-${pad(at.getMinutes())}-${pad(at.getSeconds())}`;
  return `${d}_${slug || "show"}_${showId}.mp4`;
}
