/**
 * Headless Google Chrome showing the render page. The page hands us MediaRecorder chunks through
 * window.__swChunk(base64) and its health through window.__swStatus(status) — both exposed before it loads.
 * Real Chrome (not Playwright's Chromium) because the phone feeds are H.264/AAC HLS.
 */
import { chromium, type Browser } from "playwright-core";
import { STUDIO_HEIGHT, STUDIO_WIDTH, type RenderStatus } from "../../shared/types.js";
import { log, rateLimited } from "./log.js";

export interface RenderOpts {
  url: string;
  chromePath: string | null;
  extraArgs?: string[];
  onChunk: (buf: Buffer) => Promise<void>;
  onStatus: (s: RenderStatus) => void;
  /** browser crashed / page closed */
  onExit: (reason: string) => void;
}

/** Keep the page rendering at full speed with nobody watching. Not --mute-audio: the recorder needs the audio. */
export const CHROME_ARGS = [
  "--autoplay-policy=no-user-gesture-required",
  "--disable-background-timer-throttling",
  "--disable-renderer-backgrounding",
  "--disable-backgrounding-occluded-windows",
  "--disable-features=CalculateNativeWinOcclusion",
  "--ignore-gpu-blocklist",
  "--enable-gpu-rasterization",
  "--no-first-run",
  "--no-default-browser-check",
];

/** Thrown when Chrome itself is missing: retrying won't help. */
export class ChromeMissingError extends Error {}

export function isChromeMissing(message: string): boolean {
  return /distribution 'chrome' is not found|Executable doesn't exist|ENOENT/i.test(message);
}

export interface RenderProcess {
  start(): Promise<void>;
  stop(): Promise<void>;
}

export class RenderBrowser implements RenderProcess {
  private browser: Browser | null = null;
  private closing = false;

  constructor(private readonly opts: RenderOpts) {}

  async start(): Promise<void> {
    const o = this.opts;
    try {
      this.browser = await chromium.launch({
        headless: true,
        ...(o.chromePath ? { executablePath: o.chromePath } : { channel: "chrome" }),
        args: [...CHROME_ARGS, ...(o.extraArgs ?? [])],
      });
    } catch (err) {
      const msg = (err as Error).message ?? String(err);
      if (isChromeMissing(msg)) {
        throw new ChromeMissingError(
          o.chromePath ? `Google Chrome was not found at ${o.chromePath} (CHROME_PATH).` : "Google Chrome is not installed on this PC. Install it, or set CHROME_PATH.",
        );
      }
      throw new Error(`Chrome could not start: ${msg.split("\n")[0]}`);
    }
    if (this.closing) return void (await this.stop());
    this.browser.on("disconnected", () => this.exit("Chrome closed unexpectedly"));
    const context = await this.browser.newContext({ viewport: { width: STUDIO_WIDTH, height: STUDIO_HEIGHT }, deviceScaleFactor: 1 });
    await context.exposeBinding("__swChunk", async (_src, b64: unknown) => {
      if (typeof b64 === "string" && b64.length && !this.closing) await o.onChunk(Buffer.from(b64, "base64"));
    });
    await context.exposeBinding("__swStatus", (_src, s: unknown) => {
      if (s && typeof s === "object" && !this.closing) {
        const r = s as Partial<RenderStatus>;
        o.onStatus({ fps: Number(r.fps) || 0, recording: !!r.recording, error: typeof r.error === "string" ? r.error : null });
      }
    });

    const page = await context.newPage();
    const consoleLog = rateLimited(10, 30_000);
    page.on("console", (m) => {
      if (m.type() === "error" || m.type() === "warning") {
        consoleLog((dropped) => log.warn(`page ${m.type()}: ${m.text().slice(0, 300)}`, dropped ? { dropped } : undefined));
      }
    });
    page.on("pageerror", (err) => consoleLog((dropped) => log.warn(`page error: ${err.message.slice(0, 300)}`, dropped ? { dropped } : undefined)));
    page.on("crash", () => this.exit("The render page crashed"));
    page.on("close", () => this.exit("The render page closed"));
    const res = await page.goto(o.url, { waitUntil: "domcontentloaded", timeout: 30_000 });
    if (res && !res.ok()) throw new Error(`The render page answered ${res.status()}`);
  }

  private exit(reason: string) {
    if (this.closing) return;
    this.closing = true;
    this.opts.onExit(reason);
  }

  async stop(): Promise<void> {
    this.closing = true;
    const b = this.browser;
    this.browser = null;
    if (!b) return;
    await Promise.race([b.close().catch(() => {}), new Promise((r) => setTimeout(r, 5000))]);
  }
}
