/**
 * 7XEN Studio — the contract in code (see CONTRACT.md). Shared by the server (src/server) and the web app (src/web).
 * No imports outside studio-app/.
 */
import { z } from "zod";

export const STUDIO_WIDTH = 1280;
export const STUDIO_HEIGHT = 720;
export const DEFAULT_FPS = 60;
export const DEFAULT_VIDEO_KBPS = 6000;
/** what the render page records (local only; the renderer's ffmpeg sets the broadcast bitrate) */
export const RENDER_VIDEO_BPS = 12_000_000;
export const DEVICE_KEY_HEADER = "X-Device-Key";
export const STREAM_QUALITIES = ["480p", "720p", "1080p"] as const;
export type StreamQuality = (typeof STREAM_QUALITIES)[number];

export interface ApiErrorBody {
  error: { code: string; message: string; fields?: Record<string, string> };
}

// ---------------------------------------------------------------- studio

export interface StudioInfo {
  name: string;
  lanUrl: string;
  version: string;
  /** rtmp://<lan>:<port>/live — where phones publish */
  mediaRtmp: string;
  /** ffmpeg encoder the renderer uses (null until detected) */
  encoder: string | null;
  pinRequired: boolean;
  /** this browser may use the API (no PIN set, or the PIN cookie is valid) */
  authed: boolean;
}
export const settingsSchema = z.object({ name: z.string().trim().min(2, "At least 2 characters").max(40).optional() });
export type SettingsInput = z.infer<typeof settingsSchema>;
export const pinSchema = z.object({ pin: z.string().trim().min(1, "Enter the PIN").max(20) });

// ---------------------------------------------------------------- phones

export interface DeviceHealth {
  state?: "IDLE" | "LIVE";
  quality?: string;
  autoDowngraded?: boolean;
  battery?: number;
  charging?: boolean;
  thermal?: "nominal" | "fair" | "serious" | "critical";
  cpuPct?: number;
  memMB?: number;
  fps?: number;
  bitrateKbps?: number;
  width?: number;
  height?: number;
  network?: "wifi" | "cellular";
}
export interface Device {
  id: string;
  name: string;
  createdAt: string;
  model: string | null;
  osVersion: string | null;
  appVersion: string | null;
  lastSeenAt: string | null;
}
export interface DeviceRow extends Device {
  online: boolean;
  streaming: boolean;
  videoReady: boolean;
  streamingSince: string | null;
  health: DeviceHealth | null;
  /** same-origin HLS: /api/devices/:id/live/index.m3u8 */
  hlsUrl: string;
}
export const deviceNameSchema = z.object({ name: z.string().trim().min(2, "At least 2 characters").max(40) });
export interface CreatedDevice {
  device: DeviceRow;
  /** shown once */
  key: string;
  /** 7xen://pair?host=<lanUrl>&key=<key>&name=<studio name> */
  pairUrl: string;
}
export const pairUrl = (host: string, key: string, name: string) =>
  `7xen://pair?host=${encodeURIComponent(host)}&key=${encodeURIComponent(key)}&name=${encodeURIComponent(name)}`;

// device API (7XEN Stream app) — same contract as the app already speaks
export const deviceHelloSchema = z.object({
  deviceModel: z.string().trim().max(80).optional(),
  osVersion: z.string().trim().max(40).optional(),
  appVersion: z.string().trim().max(40).optional(),
});
export const deviceStreamStartSchema = z.object({ quality: z.enum(STREAM_QUALITIES).default("720p"), fps: z.union([z.literal(30), z.literal(60)]).optional() });
export const deviceHeartbeatSchema = z
  .object({
    state: z.enum(["IDLE", "LIVE"]).optional(),
    quality: z.string().max(10).optional(),
    autoDowngraded: z.boolean().optional(),
    battery: z.number().min(0).max(1).optional(),
    charging: z.boolean().optional(),
    thermal: z.enum(["nominal", "fair", "serious", "critical"]).optional(),
    cpuPct: z.number().min(0).max(10_000).optional(),
    memMB: z.number().min(0).max(100_000).optional(),
    fps: z.number().min(0).max(240).optional(),
    bitrateKbps: z.number().min(0).max(1_000_000).optional(),
    width: z.number().int().min(0).max(10_000).optional(),
    height: z.number().int().min(0).max(10_000).optional(),
    network: z.enum(["wifi", "cellular"]).optional(),
  })
  .passthrough();
export interface DeviceHelloResponse {
  device: { id: string; name: string };
  manager: { name: string };
  studio: { name: string };
  assignedMatch: null;
}
export interface DeviceStreamStartResponse {
  rtmpUrl: string;
  streamName: string;
  expiresAt: string;
}
export interface DeviceHeartbeatResponse {
  assignedMatch: null;
  snapshotRequests: { id: string }[];
}

// ---------------------------------------------------------------- destinations (stream keys)

export const DESTINATION_PRESETS = {
  YOUTUBE: { label: "YouTube", url: "rtmp://a.rtmp.youtube.com/live2" },
  FACEBOOK: { label: "Facebook", url: "rtmps://live-api-s.facebook.com:443/rtmp" },
  CUSTOM: { label: "Other (RTMP)", url: "" },
} as const;
export type DestinationKind = keyof typeof DESTINATION_PRESETS;
export interface Destination {
  id: string;
  name: string;
  kind: DestinationKind;
  url: string;
  /** last 4 characters of the stream key */
  keyHint: string;
}
export const destinationSchema = z.object({
  kind: z.enum(["YOUTUBE", "FACEBOOK", "CUSTOM"]),
  name: z.string().trim().min(2, "At least 2 characters").max(40),
  url: z.string().trim().regex(/^rtmps?:\/\/\S+$/i, "Must start with rtmp:// or rtmps://").max(300),
  streamKey: z.string().trim().min(4, "Paste the stream key").max(300),
});
export type DestinationInput = z.infer<typeof destinationSchema>;
export const destinationUpdateSchema = destinationSchema.partial();

// ---------------------------------------------------------------- shows

export type SourceRef =
  | { kind: "device"; id: string }
  | { kind: "camera" }
  | { kind: "prop"; id: string }
  | { kind: "slate" }
  | { kind: "image"; id: string }
  | { kind: "web"; url: string };
export type LayoutKind = "full" | "side" | "pip" | "desk" | "trio";
export interface Scene {
  id: string;
  name: string;
  layout: LayoutKind;
  slots: (SourceRef | null)[];
}
export interface Overlays {
  liveBug: boolean;
  lowerThird: boolean;
  lowerTitle: string;
  lowerSubtitle: string;
  ticker: boolean;
  tickerText: string;
  logo: { on: boolean; propId: string | null; corner: "tl" | "tr" | "bl" | "br" };
  /** a transparent web page drawn full-frame (e.g. a scoreboard URL) */
  web: { on: boolean; url: string };
  slateText: string;
}
export interface ShowConfig {
  v: 1;
  scenes: Scene[];
  overlays: Overlays;
  transition: "cut" | "fade";
  /** prop video looping on the slate scene */
  introPropId: string | null;
}
export const DEFAULT_OVERLAYS: Overlays = {
  liveBug: true,
  lowerThird: false,
  lowerTitle: "",
  lowerSubtitle: "Caster",
  ticker: false,
  tickerText: "",
  logo: { on: false, propId: null, corner: "tr" },
  web: { on: false, url: "" },
  slateText: "Starting soon",
};
export interface ShowOutputs {
  /** save the finished show on this PC */
  record: boolean;
  /** stream keys to send it to */
  destinationIds: string[];
}
export interface Show {
  id: string;
  title: string;
  createdAt: string;
  updatedAt: string;
  config: ShowConfig;
  outputs: ShowOutputs;
  fps: 30 | 60;
  videoKbps: number;
  state: "IDLE" | "LIVE";
  liveSince: string | null;
  /** linked to an integration event (e.g. an AirBattleground match) and its outputs — null = local only */
  link: ShowLink | null;
}
export interface ShowLink {
  integration: string;
  eventId: string | null;
  eventTitle: string | null;
  /** enabled IntegrationOutput ids */
  outputIds: string[];
}
const sourceRefSchema: z.ZodType<SourceRef> = z.union([
  z.object({ kind: z.literal("device"), id: z.string().min(1).max(60) }),
  z.object({ kind: z.literal("camera") }),
  z.object({ kind: z.literal("prop"), id: z.string().min(1).max(60) }),
  z.object({ kind: z.literal("slate") }),
  z.object({ kind: z.literal("image"), id: z.string().min(1).max(60) }),
  z.object({ kind: z.literal("web"), url: z.string().url().max(500) }),
]);
export const showConfigSchema = z.object({
  v: z.literal(1),
  scenes: z
    .array(z.object({ id: z.string().min(1).max(40), name: z.string().trim().min(1).max(40), layout: z.enum(["full", "side", "pip", "desk", "trio"]), slots: z.array(sourceRefSchema.nullable()).max(4) }))
    .max(30),
  overlays: z.object({
    liveBug: z.boolean(),
    lowerThird: z.boolean(),
    lowerTitle: z.string().max(80),
    lowerSubtitle: z.string().max(80),
    ticker: z.boolean(),
    tickerText: z.string().max(500),
    logo: z.object({ on: z.boolean(), propId: z.string().max(60).nullable(), corner: z.enum(["tl", "tr", "bl", "br"]) }),
    web: z.object({ on: z.boolean(), url: z.string().max(500) }),
    slateText: z.string().max(80),
  }),
  transition: z.enum(["cut", "fade"]),
  introPropId: z.string().max(60).nullable(),
});
export const createShowSchema = z.object({ title: z.string().trim().min(2, "At least 2 characters").max(80) });
export const updateShowSchema = z.object({
  title: z.string().trim().min(2, "At least 2 characters").max(80).optional(),
  config: showConfigSchema.optional(),
  outputs: z.object({ record: z.boolean(), destinationIds: z.array(z.string()).max(10) }).optional(),
  fps: z.union([z.literal(30), z.literal(60)]).optional(),
  videoKbps: z.number().int().min(1000).max(20_000).optional(),
  link: z
    .object({ integration: z.string().min(1).max(40), eventId: z.string().max(60).nullable(), eventTitle: z.string().max(200).nullable(), outputIds: z.array(z.string().max(80)).max(20) })
    .nullable()
    .optional(),
});
export type UpdateShowInput = z.infer<typeof updateShowSchema>;

/** live switching state the console mirrors to the renderer */
export interface Control {
  version: number;
  programId: string | null;
  takeSeq: number;
}
export interface ControlState extends Control {
  config: ShowConfig;
  title: string;
  state: "IDLE" | "LIVE";
  liveSince: string | null;
}
export const controlSchema = z.object({ programId: z.string().max(40).nullable(), takeSeq: z.number().int().min(0) });

export type RendererState = "idle" | "starting" | "live" | "error";
export interface ShowStatus {
  state: "IDLE" | "LIVE";
  liveSince: string | null;
  renderer: { state: RendererState; fps: number | null; encoder: string | null; bitrateKbps: number | null; error: string | null };
  outputs: { id: string; name: string; kind: "record" | "rtmp" | "preview"; ok: boolean; error: string | null }[];
  recordingFile: string | null;
}

/** What the render page reports through window.__swStatus. */
export interface RenderStatus {
  fps: number;
  recording: boolean;
  error: string | null;
}

// ---------------------------------------------------------------- props + recordings

export interface Prop {
  id: string;
  name: string;
  kind: "video" | "image";
  sizeBytes: number;
  /** /api/props/:id/file */
  url: string;
}
export interface Recording {
  file: string;
  title: string;
  showId: string | null;
  sizeBytes: number;
  startedAt: string;
  updatedAt: string;
  recording: boolean;
}
export interface Recordings {
  items: Recording[];
  disk: { freeBytes: number; totalBytes: number };
}
export interface ListResponse<T> {
  items: T[];
}

// ---------------------------------------------------------------- integrations (extensions)

export interface IntegrationInfo {
  id: string;
  name: string;
  connected: boolean;
  account: { name: string; org: string | null } | null;
  host: string | null;
  error: string | null;
}
export interface StudioEvent {
  id: string;
  title: string;
  subtitle: string;
  startsAt: string | null;
  status: "upcoming" | "live" | "done";
}
export interface IntegrationOutput {
  id: string;
  name: string;
  kind: "live-page" | "youtube" | "rtmp";
  defaultOn: boolean;
}
export const connectIntegrationSchema = z.object({ link: z.string().trim().min(4, "Scan the QR or paste the link").max(500) });
export const CAPTURE_KINDS = ["SLOT_LIST", "RESULTS"] as const;
export type CaptureKind = (typeof CAPTURE_KINDS)[number];
