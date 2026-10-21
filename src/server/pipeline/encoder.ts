/**
 * ffmpeg command lines: which H.264 encoder this machine has (GPU first, CPU libx264 last) and the full
 * "WebM on stdin → H.264/AAC → tee (recording file + RTMP)" argument list. Everything except the probe runner is pure.
 */
import { spawn } from "node:child_process";
import os from "node:os";
import { STUDIO_HEIGHT, STUDIO_WIDTH } from "../../shared/types.js";

/**
 * libx264 "faster" only from this many logical cores. Measured on an 8-thread laptop: faster runs 720p60 at 1.1x
 * alone and falls behind real time next to Chrome (which takes ~2.7 cores); veryfast runs at 2.3x.
 */
export const X264_FASTER_CORES = 16;

export type Encoder = "h264_nvenc" | "h264_qsv" | "h264_amf" | "h264_videotoolbox" | "libx264" | (string & {});

export interface VideoOpts {
  fps: number;
  kbps: number;
  /** logical CPU cores (libx264 preset choice) */
  cores: number;
}

/** Encoders worth trying on this platform, best first. */
export function candidates(platform: NodeJS.Platform = process.platform): Encoder[] {
  if (platform === "darwin") return ["h264_videotoolbox", "libx264"];
  return ["h264_nvenc", "h264_qsv", "h264_amf", "libx264"];
}

export function isHardware(encoder: Encoder): boolean {
  return encoder !== "libx264";
}

/** Video encoder arguments: constant bitrate, no B-frames, a keyframe every 2 s, constant frame rate. */
export function videoArgs(encoder: Encoder, o: VideoOpts): string[] {
  const k = Math.round(o.kbps);
  const rate = ["-b:v", `${k}k`, "-maxrate", `${k}k`, "-bufsize", `${k * 2}k`];
  const gop = ["-g", String(Math.round(o.fps * 2)), "-force_key_frames", "expr:gte(t,n_forced*2)"];
  let codec: string[];
  switch (encoder) {
    case "h264_nvenc":
      codec = ["-c:v", "h264_nvenc", "-preset", "p4", "-tune", "ll", "-rc", "cbr", "-bf", "0", "-profile:v", "high", "-spatial-aq", "1"];
      break;
    case "h264_qsv":
      codec = ["-c:v", "h264_qsv", "-preset", "veryfast", "-bf", "0", "-look_ahead", "0", "-profile:v", "high"];
      break;
    case "h264_amf":
      codec = ["-c:v", "h264_amf", "-usage", "lowlatency", "-quality", "speed", "-rc", "cbr", "-bf", "0", "-profile:v", "high"];
      break;
    case "h264_videotoolbox":
      codec = ["-c:v", "h264_videotoolbox", "-realtime", "1", "-profile:v", "high", "-allow_sw", "1"];
      break;
    case "libx264":
      codec = [
        "-c:v", "libx264",
        "-preset", o.cores >= X264_FASTER_CORES ? "faster" : "veryfast",
        "-tune", "zerolatency",
        "-profile:v", "high",
        "-x264-params", "nal-hrd=cbr:force-cfr=1",
      ];
      break;
    default:
      // an ENCODER override we don't know: pick it and trust its defaults
      codec = ["-c:v", encoder];
  }
  const pix = ["-pix_fmt", isHardware(encoder) ? "nv12" : "yuv420p"];
  const size = ["-s", `${STUDIO_WIDTH}x${STUDIO_HEIGHT}`, "-fps_mode", "cfr", "-r", String(o.fps)];
  return [...codec, ...rate, ...gop, ...pix, ...size];
}

// ------------------------------------------------------------------ outputs (tee)

export interface TeeSlave {
  kind: "record" | "rtmp" | "preview";
  /** record: the .mp4 file path; rtmp/preview: the full RTMP(S) URL */
  url: string;
}

/** Escape one URL/path for the tee muxer's slave list (av_get_token: backslash escapes; `|` separates slaves). */
export function escapeTeeUrl(url: string): string {
  return url.replace(/[\\'|[\]]/g, (c) => `\\${c}`);
}

/**
 * Fragmented MP4: playable while it's being written and safe if the PC loses power (everything up to the last
 * fragment is kept). A plain MP4 would be unreadable without its final index.
 */
export const RECORD_SLAVE = "[f=mp4:movflags=+frag_keyframe+empty_moov+default_base_moof:onfail=ignore]";
/** onfail=ignore: one dead destination (a revoked stream key) doesn't take the others down. */
export const RTMP_SLAVE = "[f=flv:onfail=ignore:flvflags=no_duration_filesize]";

/** tee muxer filename writing to every slave at once. */
export function teeTarget(slaves: TeeSlave[]): string {
  return slaves.map((s) => `${s.kind === "record" ? RECORD_SLAVE : RTMP_SLAVE}${escapeTeeUrl(s.url)}`).join("|");
}

/** Where the encoded show goes: always the tee muxer (stable slave indexes for per-output health); none → null muxer. */
export function outputArgs(slaves: TeeSlave[]): string[] {
  if (slaves.length === 0) return ["-f", "null", "-"];
  // FLV / fragmented MP4 want codec headers out of band; through tee ffmpeg can't detect that, so ask for it
  return ["-flags", "+global_header", "-f", "tee", teeTarget(slaves)];
}

/** Full ffmpeg argument list: WebM (MediaRecorder chunks) on stdin → H.264/AAC → every slave. */
export function ffmpegArgs(encoder: Encoder, o: VideoOpts & { slaves: TeeSlave[] }): string[] {
  return [
    "-hide_banner", "-loglevel", "warning", "-nostats", "-y",
    "-fflags", "+genpts+discardcorrupt",
    "-f", "webm", "-i", "pipe:0",
    "-map", "0:v:0", "-map", "0:a:0?",
    ...videoArgs(encoder, o),
    "-c:a", "aac", "-b:a", "160k", "-ar", "48000", "-ac", "2",
    "-progress", "pipe:1", "-stats_period", "2",
    ...outputArgs(o.slaves),
  ];
}

// ------------------------------------------------------------------ detection

/** A 1-frame synthetic encode — succeeds only when the encoder (and its GPU/driver) actually works. */
export function probeArgs(encoder: Encoder, o: VideoOpts): string[] {
  return [
    "-hide_banner", "-loglevel", "error",
    "-f", "lavfi", "-i", `color=c=black:s=${STUDIO_WIDTH}x${STUDIO_HEIGHT}:r=${o.fps}`,
    "-frames:v", "1",
    ...videoArgs(encoder, o),
    "-f", "null", "-",
  ];
}

export type ProbeRunner = (ffmpegPath: string, args: string[]) => Promise<{ ok: boolean; stdout: string; stderr: string }>;

const runProbe: ProbeRunner = (ffmpegPath, args) =>
  new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let child;
    try {
      child = spawn(ffmpegPath, args, { stdio: ["ignore", "pipe", "pipe"] });
    } catch (err) {
      resolve({ ok: false, stdout, stderr: String(err) });
      return;
    }
    const timer = setTimeout(() => child.kill("SIGKILL"), 20_000);
    child.stdout.on("data", (d: Buffer) => (stdout += d.toString()));
    child.stderr.on("data", (d: Buffer) => (stderr += d.toString()));
    child.on("error", (err) => {
      clearTimeout(timer);
      resolve({ ok: false, stdout, stderr: String(err) });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ ok: code === 0, stdout, stderr });
    });
  });

/** `ffmpeg -encoders` output → encoder names */
export function parseEncoders(text: string): Set<string> {
  const names = new Set<string>();
  for (const line of text.split("\n")) {
    const m = /^\s*[VAS][.A-Z]{5}\s+(\S+)/.exec(line);
    if (m && m[1] !== "=") names.add(m[1]!);
  }
  return names;
}

export interface Detection {
  encoder: Encoder;
  /** why the better ones were skipped (encoder → first error line) */
  skipped: Record<string, string>;
}

/**
 * First encoder that encodes one frame. An ENCODER override is still tested (so a typo is logged) but used even if
 * the test fails — the person asked for it. Throws when nothing works (ffmpeg missing).
 */
export async function probeEncoder(
  ffmpegPath: string,
  opts: { override?: string | null; fps?: number; kbps?: number; platform?: NodeJS.Platform; cores?: number; run?: ProbeRunner } = {},
): Promise<Detection> {
  const run = opts.run ?? runProbe;
  const o: VideoOpts = { fps: opts.fps ?? 60, kbps: opts.kbps ?? 6000, cores: opts.cores ?? os.cpus().length };
  const skipped: Record<string, string> = {};
  const firstLine = (s: string) => s.trim().split("\n").find((l) => l.trim())?.slice(0, 200) ?? "failed";
  if (opts.override) {
    const r = await run(ffmpegPath, probeArgs(opts.override, o));
    if (!r.ok) skipped[opts.override] = firstLine(r.stderr);
    return { encoder: opts.override, skipped };
  }
  const list = await run(ffmpegPath, ["-hide_banner", "-encoders"]);
  if (!list.ok) throw new Error(`ffmpeg was not found or does not work (${ffmpegPath}). Install ffmpeg or set FFMPEG_PATH.`);
  const built = parseEncoders(list.stdout);
  for (const enc of candidates(opts.platform)) {
    if (!built.has(enc)) {
      skipped[enc] = "not in this ffmpeg build";
      continue;
    }
    const r = await run(ffmpegPath, probeArgs(enc, o));
    if (r.ok) return { encoder: enc, skipped };
    skipped[enc] = firstLine(r.stderr);
  }
  throw new Error(`This ffmpeg cannot encode H.264 (${ffmpegPath}). Install a full ffmpeg build or set FFMPEG_PATH.`);
}

export const defaultFfmpegPath = (p?: string | null) => p || process.env.FFMPEG_PATH || "ffmpeg";

const cache = new Map<string, Promise<Detection>>();
let lastDetected: string | null = null;

/**
 * The encoder this PC uses, detected once (cached per ffmpeg path + override). Defaults come from the env
 * (FFMPEG_PATH, ENCODER). Rejects when ffmpeg is missing; a failed detection is retried on the next call.
 */
export function detectEncoder(opts: { ffmpegPath?: string | null; override?: string | null } = {}): Promise<string> {
  const ffmpegPath = defaultFfmpegPath(opts.ffmpegPath);
  const override = opts.override ?? (process.env.ENCODER || null);
  const key = `${ffmpegPath}\0${override ?? ""}`;
  let p = cache.get(key);
  if (!p) {
    p = probeEncoder(ffmpegPath, { override });
    cache.set(key, p);
    p.then(
      (d) => (lastDetected = d.encoder),
      () => cache.delete(key),
    );
  }
  return p.then((d) => d.encoder);
}

/** The last detected encoder, synchronously (null until detectEncoder() resolved once). */
export const detectedEncoder = (): string | null => lastDetected;

// ------------------------------------------------------------------ progress

/** Running ffmpeg `-progress` output → kbps actually written, encode fps, and how far the output got. */
export class ProgressMeter {
  private buf = "";
  private block: Record<string, string> = {};
  private last: { bytes: number; at: number } | null = null;
  private lastFrame: { frame: number; at: number } | null = null;
  kbps: number | null = null;
  fps: number | null = null;
  /** seconds of output written so far */
  outSeconds = 0;
  /** out_time moved forward in the last completed block */
  advancing = false;

  constructor(private readonly now: () => number = Date.now) {}

  /** feed raw stdout; returns true when a progress block completed */
  feed(text: string): boolean {
    this.buf += text;
    let completed = false;
    let nl: number;
    while ((nl = this.buf.indexOf("\n")) >= 0) {
      const line = this.buf.slice(0, nl).trim();
      this.buf = this.buf.slice(nl + 1);
      const eq = line.indexOf("=");
      if (eq < 0) continue;
      this.block[line.slice(0, eq)] = line.slice(eq + 1).trim();
      if (line.startsWith("progress=")) {
        this.finishBlock();
        completed = true;
      }
    }
    return completed;
  }

  private finishBlock() {
    const b = this.block;
    this.block = {};
    const us = Number(b.out_time_us ?? b.out_time_ms);
    const prev = this.outSeconds;
    if (Number.isFinite(us) && us > 0) this.outSeconds = us / 1e6;
    this.advancing = this.outSeconds > prev;
    const at = this.now();
    // encode fps over the last block (ffmpeg's own fps= is the average since start)
    const frame = Number(b.frame);
    if (Number.isFinite(frame) && frame >= 0) {
      if (this.lastFrame && at > this.lastFrame.at && frame >= this.lastFrame.frame) {
        this.fps = Math.round(((frame - this.lastFrame.frame) * 10000) / (at - this.lastFrame.at)) / 10;
      }
      this.lastFrame = { frame, at };
    }
    if (this.fps === null) {
      const fps = Number(b.fps);
      if (Number.isFinite(fps) && fps > 0) this.fps = Math.round(fps * 10) / 10;
    }
    const bytes = Number(b.total_size);
    if (Number.isFinite(bytes) && bytes >= 0) {
      if (this.last && at > this.last.at && bytes >= this.last.bytes) {
        this.kbps = Math.round(((bytes - this.last.bytes) * 8) / (at - this.last.at));
      }
      this.last = { bytes, at };
    }
    if (this.kbps === null) {
      const m = /([\d.]+)\s*kbits\/s/.exec(b.bitrate ?? "");
      if (m) this.kbps = Math.round(Number(m[1]));
    }
  }
}
