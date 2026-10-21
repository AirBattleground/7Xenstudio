/** Studio settings from the environment (`--env-file-if-exists=.env`, see .env.example). */
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export interface Config {
  port: number;
  /** LAN address phones and browsers use to reach this PC */
  lanHost: string;
  /** http://<lanHost>:<port> unless LAN_URL overrides it */
  lanUrl: string;
  /** default studio name (the settings page can override it) */
  studioName: string;
  /** "" = no PIN, the studio is open on the LAN */
  pin: string;
  dataDir: string;
  mediaRtmpPort: number;
  mediaHlsUrl: string;
  mediaApiUrl: string;
  webDist: string;
  ffmpegPath: string | null;
  chromePath: string | null;
  encoder: string | null;
}

export const APP_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

const PRIVATE_V4 = [/^10\./, /^192\.168\./, /^172\.(1[6-9]|2\d|3[01])\./];

/** First private IPv4 of this machine (Wi-Fi / Ethernet), else 127.0.0.1. */
export function detectLanHost(ifaces: NodeJS.Dict<os.NetworkInterfaceInfo[]> = os.networkInterfaces()): string {
  const all = Object.entries(ifaces)
    // docker / VPN bridges are never what the phones can reach
    .filter(([name]) => !/^(docker|br-|veth|virbr|tun|tap|wg|zt|tailscale|lo)/i.test(name))
    .flatMap(([, list]) => list ?? [])
    .filter((i) => i.family === "IPv4" && !i.internal);
  return all.find((i) => PRIVATE_V4.some((re) => re.test(i.address)))?.address ?? all[0]?.address ?? "127.0.0.1";
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const blank = (v: string | undefined) => (v && v.trim() ? v.trim() : null);
  const num = (v: string | undefined, d: number) => {
    const n = Number(blank(v) ?? d);
    return Number.isInteger(n) && n > 0 && n < 65536 ? n : d;
  };
  const resolve = (p: string) => (path.isAbsolute(p) ? p : path.resolve(APP_DIR, p));
  const port = num(env.PORT, 4400);
  const lanHost = blank(env.LAN_HOST) ?? detectLanHost();
  return {
    port,
    lanHost,
    lanUrl: (blank(env.LAN_URL) ?? `http://${lanHost}:${port}`).replace(/\/+$/, ""),
    studioName: (blank(env.STUDIO_NAME) ?? "7XEN Studio").slice(0, 40),
    pin: blank(env.STUDIO_PIN) ?? "",
    dataDir: resolve(blank(env.DATA_DIR) ?? "./data"),
    mediaRtmpPort: num(env.MEDIA_RTMP_PORT, 1940),
    mediaHlsUrl: (blank(env.MEDIA_HLS_URL) ?? "http://127.0.0.1:8893").replace(/\/+$/, ""),
    mediaApiUrl: (blank(env.MEDIA_API_URL) ?? "http://127.0.0.1:9994").replace(/\/+$/, ""),
    webDist: resolve(blank(env.WEB_DIST) ?? "./dist/web"),
    ffmpegPath: blank(env.FFMPEG_PATH),
    chromePath: blank(env.CHROME_PATH),
    encoder: blank(env.ENCODER),
  };
}
