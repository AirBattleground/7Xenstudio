/**
 * The Studio mixer: draws the on-air scene (plus overlays) onto a 1280×720 canvas at the show's frame rate and mixes
 * the audio of what's on air. The console runs one for its Program/Preview monitors; the render page (headless Chrome
 * on this PC, driven by the server) runs one and records it with `startCapture` — that recording is the real output.
 *
 * - The clock is a Web Worker timer, so drawing keeps going when the tab is in the background (rAF would pause).
 * - Phones play their same-origin HLS (`/api/devices/<id>/live/index.m3u8`) through hls.js; prop videos and images
 *   come from `/api/props/<id>/file`; the webcam from getUserMedia.
 * - "Web" sources and the web overlay are image URLs that update (e.g. a scoreboard PNG endpoint): re-fetched every
 *   2 s and drawn. A web *page* can't be drawn on a canvas, so the URL must return an image. Other sites' images
 *   load with CORS (crossOrigin="anonymous"); one that doesn't allow it shows a note instead of tainting the canvas.
 * - Audio: every source has a gain; on-air sources fade up, the rest down. Nothing plays on the speakers unless
 *   "monitor" is on. A silent ConstantSource keeps the mix's audio track producing samples (MediaRecorder emits
 *   nothing without them in headless Chrome).
 */
import type Hls from "hls.js";
import { DEFAULT_FPS, STUDIO_HEIGHT as H, STUDIO_WIDTH as W } from "@shared/types";
import { LAYOUTS, type Rect } from "./layouts";
import { DEFAULT_OVERLAYS, sourceKey, type Overlays, type Scene, type SourceRef } from "./types";

export interface MixerStatus {
  /** frames the mixer actually drew in the last second */
  fps: number;
}

interface Src {
  ref: SourceRef;
  video: HTMLVideoElement | null;
  hls: Hls | null;
  gain: GainNode | null;
  stream: MediaStream | null;
  image: PolledImage | null;
  ready: boolean;
  error: string | null;
}

const FONT = "Rajdhani, Inter, system-ui, sans-serif";
const TEAL = "#2dd4c4";

/** A worker-driven interval: keeps ticking in background tabs (rAF and main-thread timers get throttled). */
export function workerTicker(fps: number, onTick: () => void): () => void {
  const code = `let t=setInterval(()=>postMessage(0),${Math.round(1000 / fps)});onmessage=()=>{clearInterval(t)}`;
  const url = URL.createObjectURL(new Blob([code], { type: "text/javascript" }));
  const w = new Worker(url);
  w.onmessage = onTick;
  return () => {
    w.postMessage(0);
    w.terminate();
    URL.revokeObjectURL(url);
  };
}

/** The recorder format: H.264 in WebM when the browser can (cheaper for the renderer's ffmpeg), else VP8. */
export function pickCaptureMime(isSupported: (m: string) => boolean): string {
  const options = ["video/webm;codecs=h264,opus", "video/webm;codecs=vp8,opus", "video/webm;codecs=vp9,opus", "video/webm"];
  return options.find((m) => isSupported(m)) ?? "video/webm";
}

/** `url` with a cache-busting parameter (so a polled image really reloads). data:/blob: URLs are left alone. */
export function cacheBust(url: string, now = Date.now()): string {
  if (/^(data|blob):/i.test(url)) return url;
  const [base, hash] = url.split("#", 2) as [string, string | undefined];
  return `${base}${base.includes("?") ? "&" : "?"}_sw=${now}${hash !== undefined ? `#${hash}` : ""}`;
}

/** An image that (optionally) reloads every `intervalMs`, keeping the last good frame while the next one loads. */
export class PolledImage {
  img: HTMLImageElement | null = null;
  error: string | null = null;
  private timer: number | null = null;
  private alive = true;
  private loading = false;

  constructor(
    readonly url: string,
    intervalMs: number,
    private external: boolean,
  ) {
    this.load(false);
    if (intervalMs > 0) this.timer = window.setInterval(() => this.load(true), intervalMs);
  }

  private load(bust: boolean) {
    if (this.loading) return;
    this.loading = true;
    const i = new Image();
    if (this.external) i.crossOrigin = "anonymous";
    i.decoding = "async";
    i.onload = () => {
      this.loading = false;
      if (!this.alive) return;
      this.img = i;
      this.error = null;
    };
    i.onerror = () => {
      this.loading = false;
      if (!this.alive) return;
      if (!this.img) this.error = this.external ? "Couldn't load this image URL (it must be an image that allows embedding)" : "Couldn't load this image";
    };
    i.src = bust ? cacheBust(this.url) : this.url;
  }

  get drawable(): HTMLImageElement | null {
    return this.img && this.img.complete && this.img.naturalWidth ? this.img : null;
  }

  dispose() {
    this.alive = false;
    if (this.timer !== null) window.clearInterval(this.timer);
  }
}

let nextId = 1;

export class StudioMixer {
  readonly id = nextId++;
  readonly canvas: HTMLCanvasElement;
  readonly fps: number;
  private ctx: CanvasRenderingContext2D;
  private audio: AudioContext;
  private dest: MediaStreamAudioDestinationNode;
  private monitor: GainNode;
  private sources = new Map<string, Src>();
  private stopTicker: (() => void) | null = null;

  private program: Scene | null = null;
  private previous: Scene | null = null;
  private transitionStart = 0;
  private transitionMs = 0;
  overlays: Overlays = { ...DEFAULT_OVERLAYS };
  /** small line above the slate text (the studio name) */
  slateTitle = "7XEN STUDIO";
  /** where a phone's HLS comes from */
  deviceUrl: (id: string) => string = (id) => `/api/devices/${encodeURIComponent(id)}/live/index.m3u8`;
  /** same-origin media URL → what <video>/<img> load (the render page adds its token) */
  mediaUrl: (path: string) => string = (p) => p;
  /** extra headers hls.js sends (the render page's token) */
  hlsHeaders: Record<string, string> = {};

  /** prop images (logo overlay) and the web overlay, loaded on demand */
  private overlayImages = new Map<string, PolledImage>();
  private webOverlay: PolledImage | null = null;

  /** LIVE-bug clock start (ms) while the show is live; null hides the bug */
  private clockSince: number | null = null;

  private captureRec: MediaRecorder | null = null;
  private captureChain: Promise<void> = Promise.resolve();
  /** recording state of startCapture (and the last hand-over error) */
  capture = { recording: false, error: null as string | null, mime: "" };
  status: MixerStatus = { fps: 0 };
  onStatus: ((s: MixerStatus) => void) | null = null;

  constructor(opts?: { fps?: number }) {
    this.fps = opts?.fps ?? DEFAULT_FPS;
    this.canvas = document.createElement("canvas");
    this.canvas.width = W;
    this.canvas.height = H;
    this.ctx = this.canvas.getContext("2d", { alpha: false })!;
    this.audio = new AudioContext();
    this.dest = this.audio.createMediaStreamDestination();
    // a silent source keeps the mix's audio track producing samples even when nothing on air has sound — without it
    // MediaRecorder (H.264/VP8 + Opus) emits no data at all in headless Chrome
    const silence = this.audio.createConstantSource();
    const mute = this.audio.createGain();
    mute.gain.value = 0;
    silence.connect(mute).connect(this.dest);
    silence.start();
    this.monitor = this.audio.createGain();
    this.monitor.gain.value = 0;
    this.monitor.connect(this.audio.destination);
    let frames = 0;
    let since = performance.now();
    this.stopTicker = workerTicker(this.fps, () => {
      this.draw();
      frames++;
      // measure the real frame rate about once a second
      const now = performance.now();
      if (now - since >= 1000) {
        this.status = { fps: Math.round((frames * 1000) / (now - since)) };
        frames = 0;
        since = now;
        this.onStatus?.(this.status);
      }
    });
  }

  dispose() {
    this.stopTicker?.();
    this.stopCapture();
    for (const s of this.sources.values()) this.dropSource(s);
    this.sources.clear();
    for (const i of this.overlayImages.values()) i.dispose();
    this.overlayImages.clear();
    this.webOverlay?.dispose();
    void this.audio.close().catch(() => undefined);
  }

  // ---------------------------------------------------------------- sources

  /** Make sure every source a scene needs is loaded (phone feeds, props, images, camera). */
  async prepare(refs: (SourceRef | null)[]) {
    // resume() can stay pending forever where there's no audio output (headless Chrome) — never await it unbounded
    await this.resumeAudio();
    await Promise.all(refs.filter((r): r is SourceRef => !!r).map((r) => this.ensure(r)));
  }

  private async ensure(ref: SourceRef): Promise<Src> {
    const key = sourceKey(ref);
    const have = this.sources.get(key);
    if (have) return have;
    const src: Src = { ref, video: null, hls: null, gain: null, stream: null, image: null, ready: false, error: null };
    this.sources.set(key, src);
    if (ref.kind === "device" || ref.kind === "prop" || ref.kind === "camera") {
      const v = document.createElement("video");
      v.playsInline = true;
      v.muted = ref.kind === "camera"; // the webcam's picture only
      v.crossOrigin = "anonymous";
      src.video = v;
      if (ref.kind !== "camera") {
        const node = this.audio.createMediaElementSource(v);
        src.gain = this.audio.createGain();
        src.gain.gain.value = 0;
        node.connect(src.gain);
        src.gain.connect(this.dest);
        src.gain.connect(this.monitor);
      }
      try {
        if (ref.kind === "device") await this.attachHls(src, this.deviceUrl(ref.id));
        else if (ref.kind === "prop") {
          v.src = this.mediaUrl(`/api/props/${encodeURIComponent(ref.id)}/file`);
          v.loop = true;
          v.onerror = () => (src.error = "Couldn't play this video");
        } else {
          src.stream = await navigator.mediaDevices.getUserMedia({ video: { width: 1280, height: 720 }, audio: false });
          v.srcObject = src.stream;
        }
        await v.play().catch(() => undefined);
        src.ready = true;
      } catch (e) {
        src.error = ref.kind === "camera" ? "Allow the webcam in the browser to show it" : e instanceof Error ? e.message : "Couldn't open this source";
      }
    } else if (ref.kind === "image") {
      src.image = new PolledImage(this.mediaUrl(`/api/props/${encodeURIComponent(ref.id)}/file`), 0, false);
      src.ready = true;
    } else if (ref.kind === "web") {
      src.image = new PolledImage(ref.url, 2000, !ref.url.startsWith("/"));
      src.ready = true;
    } else {
      src.ready = true;
    }
    return src;
  }

  private async attachHls(src: Src, url: string) {
    const v = src.video!;
    const { default: HlsCtor } = await import("hls.js");
    if (HlsCtor.isSupported()) {
      const headers = this.hlsHeaders;
      const h = new HlsCtor({
        lowLatencyMode: true,
        liveSyncDurationCount: 2,
        maxLiveSyncPlaybackRate: 1.5,
        xhrSetup: (xhr) => {
          xhr.withCredentials = true;
          for (const [k, val] of Object.entries(headers)) xhr.setRequestHeader(k, val);
        },
      });
      src.hls = h;
      h.loadSource(url);
      h.attachMedia(v);
      h.on(HlsCtor.Events.ERROR, (_e, data) => {
        if (!data.fatal) return;
        src.error = "The phone's video dropped — retrying…";
        window.setTimeout(() => {
          if (src.hls !== h) return;
          h.loadSource(url);
          h.startLoad();
        }, 3000);
      });
      h.on(HlsCtor.Events.FRAG_LOADED, () => (src.error = null));
    } else {
      v.src = url;
    }
  }

  private dropSource(s: Src) {
    s.hls?.destroy();
    s.hls = null;
    s.stream?.getTracks().forEach((t) => t.stop());
    s.image?.dispose();
    if (s.video) {
      s.video.pause();
      s.video.removeAttribute("src");
      s.video.srcObject = null;
      s.video.load();
    }
    s.gain?.disconnect();
  }

  /** Forget a source (e.g. a prop that was deleted, or the webcam turned off). */
  release(ref: SourceRef) {
    const key = sourceKey(ref);
    const s = this.sources.get(key);
    if (!s) return;
    this.dropSource(s);
    this.sources.delete(key);
  }

  sourceState(ref: SourceRef): { ready: boolean; error: string | null } {
    const s = this.sources.get(sourceKey(ref));
    return { ready: !!s?.ready, error: s?.error ?? s?.image?.error ?? null };
  }

  /** The <video> of a source (for thumbnails in the UI). */
  videoOf(ref: SourceRef): HTMLVideoElement | null {
    return this.sources.get(sourceKey(ref))?.video ?? null;
  }

  /** Wake the audio engine — bounded: resume() can hang in headless Chrome, so race it with 500 ms. */
  async resumeAudio() {
    if (this.audio.state !== "suspended") return;
    await Promise.race([this.audio.resume().catch(() => undefined), new Promise((r) => setTimeout(r, 500))]);
  }

  /** Hear the mix on this computer's speakers/headphones (console only). */
  setMonitor(on: boolean) {
    void this.resumeAudio();
    this.monitor.gain.setTargetAtTime(on ? 1 : 0, this.audio.currentTime, 0.05);
  }

  // ---------------------------------------------------------------- program

  /** Put a scene on air (cut, or fade over `fadeMs`). */
  async take(scene: Scene, fadeMs: number) {
    await this.prepare(scene.slots);
    this.previous = this.program;
    this.program = scene;
    this.transitionStart = performance.now();
    this.transitionMs = this.previous ? fadeMs : 0;
    // audio follows the picture: on-air sources up, everything else down
    const onAir = new Set(scene.slots.filter((s): s is SourceRef => !!s).map(sourceKey));
    const ramp = Math.max(0.05, fadeMs / 1000 / 3);
    for (const [key, s] of this.sources) {
      s.gain?.gain.setTargetAtTime(onAir.has(key) ? 1 : 0, this.audio.currentTime, ramp);
      if (s.video && onAir.has(key) && s.ref.kind === "prop") {
        s.video.currentTime = 0;
        void s.video.play().catch(() => undefined);
      }
    }
  }

  get onAir(): Scene | null {
    return this.program;
  }

  /** Show the LIVE bug + clock from `since` (ms); null hides it. */
  setLiveClock(since: number | null) {
    this.clockSince = since;
  }

  // ---------------------------------------------------------------- drawing

  /** Draw one scene into `ctx` (also used for the preview monitor). */
  drawScene(ctx: CanvasRenderingContext2D, scene: Scene | null) {
    ctx.fillStyle = "#06090c";
    ctx.fillRect(0, 0, W, H);
    if (!scene) {
      this.drawSlate(ctx, { x: 0, y: 0, w: W, h: H }, "Pick a scene to go on air");
      return;
    }
    const lay = LAYOUTS[scene.layout];
    if (lay.rects.some((r) => r.framed)) {
      const g = ctx.createLinearGradient(0, 0, W, H);
      g.addColorStop(0, "#0b1a1d");
      g.addColorStop(1, "#05080a");
      ctx.fillStyle = g;
      ctx.fillRect(0, 0, W, H);
    }
    lay.rects.forEach((r, i) => this.drawSlot(ctx, scene.slots[i] ?? null, r));
  }

  private drawSlot(ctx: CanvasRenderingContext2D, ref: SourceRef | null, r: Rect) {
    ctx.save();
    if (r.framed) {
      roundRect(ctx, r, 12);
      ctx.clip();
    }
    if (!ref) {
      ctx.fillStyle = "#11181c";
      ctx.fillRect(r.x, r.y, r.w, r.h);
      label(ctx, "Empty slot", r);
    } else if (ref.kind === "slate") this.drawSlate(ctx, r, this.overlays.slateText || "Starting soon");
    else {
      const s = this.sources.get(sourceKey(ref));
      const v = s?.video;
      const img = s?.image?.drawable;
      if (v && v.readyState >= 2 && v.videoWidth) drawCover(ctx, v, v.videoWidth, v.videoHeight, r, ref.kind === "camera");
      else if (img) {
        ctx.fillStyle = "#06090c";
        ctx.fillRect(r.x, r.y, r.w, r.h);
        drawContain(ctx, img, img.naturalWidth, img.naturalHeight, r);
      } else {
        ctx.fillStyle = "#0d1418";
        ctx.fillRect(r.x, r.y, r.w, r.h);
        label(ctx, s?.error ?? s?.image?.error ?? (ref.kind === "device" ? "Waiting for the phone's video…" : "Loading…"), r);
      }
    }
    ctx.restore();
    if (r.framed) {
      ctx.save();
      ctx.strokeStyle = "rgba(45,212,196,0.55)";
      ctx.lineWidth = 2;
      roundRect(ctx, r, 12);
      ctx.stroke();
      ctx.restore();
    }
  }

  private drawSlate(ctx: CanvasRenderingContext2D, r: Rect, text: string) {
    const g = ctx.createRadialGradient(r.x + r.w / 2, r.y + r.h / 2, 20, r.x + r.w / 2, r.y + r.h / 2, Math.max(r.w, r.h) * 0.7);
    g.addColorStop(0, "#0f3b3a");
    g.addColorStop(1, "#04070a");
    ctx.fillStyle = g;
    ctx.fillRect(r.x, r.y, r.w, r.h);
    ctx.fillStyle = TEAL;
    ctx.textAlign = "center";
    ctx.font = `700 ${Math.round(r.h * 0.035)}px ${FONT}`;
    ctx.fillText(this.slateTitle.toUpperCase(), r.x + r.w / 2, r.y + r.h * 0.4);
    ctx.fillStyle = "#fff";
    ctx.font = `700 ${Math.round(r.h * 0.12)}px ${FONT}`;
    fitText(ctx, text.toUpperCase(), r.x + r.w / 2, r.y + r.h * 0.55, r.w * 0.9);
    ctx.textAlign = "left";
  }

  private overlayImage(propId: string): PolledImage {
    let i = this.overlayImages.get(propId);
    if (!i) {
      i = new PolledImage(this.mediaUrl(`/api/props/${encodeURIComponent(propId)}/file`), 0, false);
      this.overlayImages.set(propId, i);
    }
    return i;
  }

  private drawOverlays(ctx: CanvasRenderingContext2D) {
    const o = this.overlays;
    // web overlay: an image URL that updates, drawn full-frame (transparent PNG over the program)
    const webUrl = o.web.on ? o.web.url.trim() : "";
    if (webUrl) {
      if (this.webOverlay?.url !== webUrl) {
        this.webOverlay?.dispose();
        this.webOverlay = new PolledImage(webUrl, 2000, !webUrl.startsWith("/"));
      }
      const img = this.webOverlay.drawable;
      if (img) ctx.drawImage(img, 0, 0, W, H);
    } else if (this.webOverlay) {
      this.webOverlay.dispose();
      this.webOverlay = null;
    }
    // logo (image prop) in a corner
    if (o.logo.on && o.logo.propId) {
      const img = this.overlayImage(o.logo.propId).drawable;
      if (img) {
        const maxW = 180;
        const maxH = 100;
        const s = Math.min(maxW / img.naturalWidth, maxH / img.naturalHeight, 1);
        const w = img.naturalWidth * s;
        const h = img.naturalHeight * s;
        const m = 28;
        const right = o.logo.corner === "tr" || o.logo.corner === "br";
        const bottom = o.logo.corner === "bl" || o.logo.corner === "br";
        // keep clear of the LIVE bug (top-right) and the ticker (bottom)
        const x = right ? W - m - w : m;
        const y = bottom ? H - m - h - (o.ticker ? 48 : 0) : m + (right && o.liveBug && this.clockSince !== null ? 46 : 0);
        ctx.drawImage(img, x, y, w, h);
      }
    }
    if (o.liveBug && this.clockSince !== null) {
      const secs = Math.max(0, Math.floor((Date.now() - this.clockSince) / 1000));
      const t = `${Math.floor(secs / 3600)}:${String(Math.floor((secs % 3600) / 60)).padStart(2, "0")}:${String(secs % 60).padStart(2, "0")}`;
      ctx.fillStyle = "#e5252a";
      ctx.fillRect(W - 210, 22, 80, 34);
      ctx.fillStyle = "rgba(0,0,0,0.65)";
      ctx.fillRect(W - 130, 22, 108, 34);
      ctx.fillStyle = "#fff";
      ctx.font = `700 22px ${FONT}`;
      ctx.fillText("● LIVE", W - 202, 47);
      ctx.fillText(t, W - 120, 47);
    }
    if (o.lowerThird && o.lowerTitle.trim()) {
      const y = H - (o.ticker ? 150 : 110);
      ctx.font = `700 30px ${FONT}`;
      const w = Math.max(320, ctx.measureText(o.lowerTitle).width + 48);
      ctx.fillStyle = TEAL;
      ctx.fillRect(40, y, 8, 64);
      ctx.fillStyle = "rgba(4,10,12,0.88)";
      ctx.fillRect(48, y, w, 64);
      ctx.fillStyle = "#fff";
      ctx.fillText(o.lowerTitle, 64, y + 32);
      ctx.fillStyle = TEAL;
      ctx.font = `600 18px ${FONT}`;
      ctx.fillText(o.lowerSubtitle.toUpperCase(), 64, y + 54);
    }
    if (o.ticker && o.tickerText.trim()) {
      ctx.fillStyle = "rgba(4,10,12,0.92)";
      ctx.fillRect(0, H - 44, W, 44);
      ctx.fillStyle = "#e5252a";
      ctx.fillRect(0, H - 44, 96, 44);
      ctx.fillStyle = "#fff";
      ctx.font = `700 20px ${FONT}`;
      ctx.fillText("LIVE", 24, H - 15);
      const text = `${o.tickerText}   ◆   `;
      const w = ctx.measureText(text).width;
      const off = ((performance.now() / 1000) * 90) % w;
      ctx.save();
      ctx.beginPath();
      ctx.rect(100, H - 44, W - 100, 44);
      ctx.clip();
      for (let x = 110 - off; x < W; x += w) ctx.fillText(text, x, H - 15);
      ctx.restore();
    }
  }

  private draw() {
    const ctx = this.ctx;
    const now = performance.now();
    const t = this.transitionMs ? Math.min(1, (now - this.transitionStart) / this.transitionMs) : 1;
    if (t < 1 && this.previous) {
      this.drawScene(ctx, this.previous);
      ctx.globalAlpha = t;
      this.drawScene(ctx, this.program);
      ctx.globalAlpha = 1;
    } else {
      this.drawScene(ctx, this.program);
    }
    this.drawOverlays(ctx);
  }

  /**
   * A still of what's on air (for captures): the program scene at 1920×1080, WITHOUT overlays (LIVE bug, lower
   * third, ticker, logo, web overlay) so they can't cover what's being captured.
   */
  snapshot(): Promise<Blob> {
    const c = document.createElement("canvas");
    c.width = 1920;
    c.height = 1080;
    const ctx = c.getContext("2d", { alpha: false })!;
    ctx.setTransform(c.width / W, 0, 0, c.height / H, 0, 0);
    this.drawScene(ctx, this.program);
    return new Promise((resolve, reject) => c.toBlob((b) => (b ? resolve(b) : reject(new Error("Couldn't take the screenshot"))), "image/png"));
  }

  // ---------------------------------------------------------------- capture (render page)

  /**
   * Record the program (canvas + audio mix): every `timesliceMs` a chunk goes to `onChunk`. Chunks are handed over
   * strictly in order — the next one waits until the previous `onChunk` has finished.
   */
  startCapture(opts: { bitsPerSecond: number; timesliceMs: number; onChunk: (b: Blob) => void | Promise<void> }) {
    if (this.captureRec) return;
    const mime = pickCaptureMime((m) => typeof MediaRecorder !== "undefined" && MediaRecorder.isTypeSupported(m));
    const stream = new MediaStream([...this.canvas.captureStream(this.fps).getVideoTracks(), ...this.dest.stream.getAudioTracks()]);
    const rec = new MediaRecorder(stream, { mimeType: mime, videoBitsPerSecond: opts.bitsPerSecond, audioBitsPerSecond: 192_000 });
    this.captureChain = Promise.resolve();
    this.capture = { recording: false, error: null, mime };
    rec.ondataavailable = (e) => {
      if (!e.data.size) return;
      const blob = e.data;
      this.captureChain = this.captureChain
        .then(() => opts.onChunk(blob))
        .then(
          () => {
            if (this.captureRec === rec) this.capture = { ...this.capture, recording: true, error: null };
          },
          (err: unknown) => {
            this.capture = { ...this.capture, recording: false, error: err instanceof Error ? err.message : "Couldn't hand the video over" };
          },
        );
    };
    rec.onerror = () => {
      this.capture = { ...this.capture, recording: false, error: "The recorder stopped" };
    };
    rec.start(opts.timesliceMs);
    this.captureRec = rec;
  }

  stopCapture() {
    const rec = this.captureRec;
    this.captureRec = null;
    if (rec && rec.state !== "inactive") rec.stop();
    rec?.stream.getVideoTracks().forEach((t) => t.stop());
    this.capture = { ...this.capture, recording: false };
  }

  get capturing(): boolean {
    return !!this.captureRec;
  }
}

// ---------------------------------------------------------------- canvas helpers

function roundRect(ctx: CanvasRenderingContext2D, r: Rect, rad: number) {
  ctx.beginPath();
  ctx.roundRect(r.x, r.y, r.w, r.h, rad);
}

/** Fill `r` with the source (cropping the overflow); `mirror` flips it (webcam). */
function drawCover(ctx: CanvasRenderingContext2D, el: CanvasImageSource, iw: number, ih: number, r: Rect, mirror: boolean) {
  const vr = iw / ih;
  const rr = r.w / r.h;
  let sw = iw;
  let sh = ih;
  if (vr > rr) sw = sh * rr;
  else sh = sw / rr;
  const sx = (iw - sw) / 2;
  const sy = (ih - sh) / 2;
  if (mirror) {
    ctx.save();
    ctx.translate(r.x + r.w, r.y);
    ctx.scale(-1, 1);
    ctx.drawImage(el, sx, sy, sw, sh, 0, 0, r.w, r.h);
    ctx.restore();
  } else ctx.drawImage(el, sx, sy, sw, sh, r.x, r.y, r.w, r.h);
}

/** Fit the whole image inside `r` (images: logos and scoreboards must not be cropped). */
function drawContain(ctx: CanvasRenderingContext2D, el: CanvasImageSource, iw: number, ih: number, r: Rect) {
  const s = Math.min(r.w / iw, r.h / ih);
  const w = iw * s;
  const h = ih * s;
  ctx.drawImage(el, r.x + (r.w - w) / 2, r.y + (r.h - h) / 2, w, h);
}

function fitText(ctx: CanvasRenderingContext2D, text: string, x: number, y: number, maxW: number) {
  ctx.fillText(text, x, y, maxW);
}

function label(ctx: CanvasRenderingContext2D, text: string, r: Rect) {
  ctx.fillStyle = "rgba(255,255,255,0.55)";
  ctx.textAlign = "center";
  ctx.font = `600 ${Math.max(14, Math.round(r.h * 0.045))}px ${FONT}`;
  ctx.fillText(text, r.x + r.w / 2, r.y + r.h / 2, r.w * 0.92);
  ctx.textAlign = "left";
}
