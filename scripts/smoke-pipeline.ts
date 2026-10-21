/**
 * Renderer smoke test — no studio server needed.
 *
 * Serves a tiny render page (animated 1280x720 canvas at 60 fps + a tone + a silent ConstantSource, recorded with
 * MediaRecorder exactly like the real render page: h264/opus or vp8/opus, 500 ms chunks → window.__swChunk), runs the
 * real pipeline (Chrome + ffmpeg) into a recording file in a temp dir AND an RTMP target received by a local
 * `ffmpeg -listen 1`, checks the recording grows while running, SIGKILLs the encoder, stops, and ffprobes both.
 *
 *   pnpm exec tsx scripts/smoke-pipeline.ts      (SECONDS_TO_RUN=20 RTMP_PORT=19360 ENCODER=… FFMPEG_PATH=… CHROME_PATH=…)
 */
import { execFileSync, spawn } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, statSync } from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { detectEncoder, startPipeline, type PipelineStatus } from "../src/server/pipeline/index.js";

const SECONDS = Number(process.env.SECONDS_TO_RUN ?? 20);
const ffmpegPath = process.env.FFMPEG_PATH || "ffmpeg";
const ffprobePath = process.env.FFPROBE_PATH || (ffmpegPath.includes("/") ? path.join(path.dirname(ffmpegPath), "ffprobe") : "ffprobe");

const PAGE = `<!doctype html><html><body style="margin:0;background:#000;overflow:hidden">
<canvas id="c" width="1280" height="720"></canvas>
<script>
const c = document.getElementById("c"), g = c.getContext("2d");
let frames = 0, fps = 0, t0 = performance.now();
function draw(now) {
  const t = now / 1000;
  g.fillStyle = "hsl(" + ((t * 40) % 360) + ",60%,20%)"; g.fillRect(0, 0, 1280, 720);
  for (let i = 0; i < 40; i++) {
    g.fillStyle = "hsl(" + (i * 9) + ",80%,60%)";
    g.fillRect(640 + Math.cos(t * 2 + i) * 500 - 20, 360 + Math.sin(t * 3 + i) * 300 - 20, 40, 40);
  }
  g.fillStyle = "#fff"; g.font = "bold 64px sans-serif"; g.fillText("7XEN Studio smoke " + t.toFixed(2), 60, 100);
  frames++;
  if (now - t0 >= 1000) { fps = frames * 1000 / (now - t0); frames = 0; t0 = now; }
  requestAnimationFrame(draw);
}
requestAnimationFrame(draw);

const ac = new AudioContext({ sampleRate: 48000 });
Promise.race([ac.resume(), new Promise((r) => setTimeout(r, 500))]); // resume() can hang headless: never await it unbounded
const dest = ac.createMediaStreamDestination();
const osc = ac.createOscillator(); osc.frequency.value = 440;
const gain = ac.createGain(); gain.gain.value = 0.2;
osc.connect(gain).connect(dest); osc.start();
const silent = ac.createConstantSource(); const sg = ac.createGain(); sg.gain.value = 0; // keeps the audio track alive
silent.connect(sg).connect(dest); silent.start();

const mime = MediaRecorder.isTypeSupported("video/webm;codecs=h264,opus") ? "video/webm;codecs=h264,opus" : "video/webm;codecs=vp8,opus";
const stream = new MediaStream([...c.captureStream(60).getVideoTracks(), ...dest.stream.getAudioTracks()]);
const rec = new MediaRecorder(stream, { mimeType: mime, videoBitsPerSecond: 12000000, audioBitsPerSecond: 128000 });
let chain = Promise.resolve(), recording = false, err = null;
const b64 = (blob) => new Promise((res, rej) => {
  const r = new FileReader();
  r.onload = () => { const s = String(r.result); res(s.slice(s.indexOf(";base64,") + 8)); }; // MIME contains a comma
  r.onerror = () => rej(r.error);
  r.readAsDataURL(blob);
});
rec.ondataavailable = (e) => {
  if (!e.data.size) return;
  const blob = e.data;
  chain = chain.then(async () => { await window.__swChunk(await b64(blob)); recording = true; }).catch((x) => { err = String(x); });
};
rec.onerror = (e) => { err = String(e.error || e); };
rec.start(500);
document.title = mime;
setInterval(() => window.__swStatus({ fps: Math.round(fps), recording, error: err }), 1000);
</script></body></html>`;

const portFree = (port: number) =>
  new Promise<boolean>((resolve) => {
    const s = net.createServer();
    s.once("error", () => resolve(false));
    s.listen(port, "127.0.0.1", () => s.close(() => resolve(true)));
  });

/** utime+stime (clock ticks) of this process's descendants, grouped as chrome / ffmpeg (encoder only). */
function cpuTicks(excludePid: number | undefined): Record<string, number> {
  const kids = new Map<number, number[]>();
  const comm = new Map<number, string>();
  const ticks = new Map<number, number>();
  for (const d of readdirSync("/proc")) {
    if (!/^\d+$/.test(d)) continue;
    try {
      const stat = readFileSync(`/proc/${d}/stat`, "utf8");
      const close = stat.lastIndexOf(")");
      const name = stat.slice(stat.indexOf("(") + 1, close);
      const f = stat.slice(close + 2).split(" ");
      const pid = Number(d);
      const ppid = Number(f[1]);
      comm.set(pid, name);
      ticks.set(pid, Number(f[11]) + Number(f[12]));
      kids.set(ppid, [...(kids.get(ppid) ?? []), pid]);
    } catch {
      /* gone */
    }
  }
  const out: Record<string, number> = { chrome: 0, ffmpeg: 0 };
  const walk = (pid: number) => {
    for (const k of kids.get(pid) ?? []) {
      if (k === excludePid) continue;
      const n = comm.get(k) ?? "";
      if (/chrom/i.test(n)) out.chrome! += ticks.get(k) ?? 0;
      else if (/ffmpeg/i.test(n)) out.ffmpeg! += ticks.get(k) ?? 0;
      walk(k);
    }
  };
  walk(process.pid);
  return out;
}

function encoderPid(excludePid: number | undefined): number | null {
  for (const d of readdirSync("/proc")) {
    if (!/^\d+$/.test(d) || Number(d) === excludePid) continue;
    try {
      const stat = readFileSync(`/proc/${d}/stat`, "utf8");
      const ppid = Number(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[1]);
      if (ppid === process.pid && /\(ffmpeg\)/.test(stat)) return Number(d);
    } catch {
      /* gone */
    }
  }
  return null;
}

function probe(file: string): string {
  try {
    return execFileSync(
      ffprobePath,
      ["-v", "error", "-count_frames", "-show_entries", "stream=codec_name,profile,width,height,r_frame_rate,avg_frame_rate,nb_read_frames,sample_rate,channels:format=duration,bit_rate", "-of", "compact", file],
      { encoding: "utf8" },
    ).trim();
  } catch (err) {
    return `ffprobe failed: ${(err as Error).message}`;
  }
}

async function main() {
  const dir = mkdtempSync(path.join(process.env.SMOKE_DIR || os.tmpdir(), "7xen-studio-smoke-"));
  const server = http.createServer((_req, res) => {
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end(PAGE);
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const pagePort = (server.address() as { port: number }).port;

  let rtmpPort = Number(process.env.RTMP_PORT ?? 19360);
  while (!(await portFree(rtmpPort))) rtmpPort++;
  let deadPort = rtmpPort + 1;
  while (!(await portFree(deadPort))) deadPort++;
  const rtmpOut = path.join(dir, "rtmp-received.flv");
  const receiver = spawn(ffmpegPath, ["-hide_banner", "-loglevel", "error", "-listen", "1", "-i", `rtmp://127.0.0.1:${rtmpPort}/live/smoke`, "-c", "copy", "-y", rtmpOut], {
    stdio: ["ignore", "ignore", "inherit"],
  });
  await new Promise((r) => setTimeout(r, 500));

  const t0 = Date.now();
  const encoder = await detectEncoder({ ffmpegPath, override: process.env.ENCODER || null });
  console.log(`encoder: ${encoder} (detected in ${Date.now() - t0} ms)  dir: ${dir}  rtmp port: ${rtmpPort}`);

  let last: PipelineStatus | null = null;
  let exitReason: string | null = null;
  const started = Date.now();
  let liveAt: number | null = null;
  const pipeline = startPipeline({
    showId: "smoke1",
    title: "Smoke Test: Evening Show!",
    slug: "smoke-test-evening-show",
    renderUrl: `http://127.0.0.1:${pagePort}/render/smoke1?t=x`,
    fps: 60,
    videoKbps: 6000,
    targets: [
      { id: "rec", name: "Recording on this PC", kind: "record", url: dir },
      { id: "rtmp", name: "Local RTMP receiver", kind: "rtmp", url: `rtmp://127.0.0.1:${rtmpPort}/live/smoke` },
      // nobody listens here: per-output health must flag it while the others keep going
      { id: "dead", name: "Dead destination", kind: "rtmp", url: `rtmp://127.0.0.1:${deadPort}/live/secret-key` },
    ],
    ffmpegPath,
    chromePath: process.env.CHROME_PATH || null,
    encoder: process.env.ENCODER || null,
    onStatus: (s) => {
      if (s.state === "live" && liveAt === null) liveAt = Date.now();
      last = s;
    },
    onExit: (r) => (exitReason = r),
  });

  const sizes: number[] = [];
  let cpuStart: { t: number; ticks: Record<string, number> } | null = null;
  const sampler = setInterval(() => {
    const s = last;
    const file = s?.recordingFile ? path.join(dir, s.recordingFile) : null;
    let size = 0;
    try {
      size = file ? statSync(file).size : 0;
    } catch {
      /* not yet */
    }
    sizes.push(size);
    const sec = Math.round((Date.now() - started) / 1000);
    if (sec >= 6 && !cpuStart) cpuStart = { t: Date.now(), ticks: cpuTicks(receiver.pid) };
    console.log(
      `t=${String(sec).padStart(2)}s state=${s?.state ?? "-"} fps=${s?.fps ?? "-"} kbps=${s?.bitrateKbps ?? "-"} rec=${(size / 1e6).toFixed(2)}MB outputs=${s?.outputs.map((o) => `${o.id}:${o.ok ? "ok" : (o.error ?? "no")}`).join(",") ?? "-"}${s?.error ? ` error="${s.error}"` : ""}`,
    );
  }, 2000);

  await new Promise((r) => setTimeout(r, SECONDS * 1000));
  clearInterval(sampler);
  const cpuEnd = { t: Date.now(), ticks: cpuTicks(receiver.pid) };
  const final = last as PipelineStatus | null;

  // SIGKILL-style stop: the encoder dies without finishing the file, like a power cut
  const pid = encoderPid(receiver.pid);
  if (pid) process.kill(pid, "SIGKILL");
  console.log(`SIGKILLed encoder pid ${pid ?? "(not found)"}`);
  await pipeline.stop();
  server.close();
  await new Promise<void>((r) => {
    const t = setTimeout(() => {
      if (receiver.exitCode === null && receiver.pid) process.kill(receiver.pid, "SIGTERM");
      r();
    }, 5000);
    receiver.once("exit", () => (clearTimeout(t), r()));
  });

  const grew = sizes.filter((s, i) => i > 0 && s > sizes[i - 1]!).length;
  console.log(`\nlive after ${liveAt ? ((liveAt - started) / 1000).toFixed(1) : "never"} s; restarts=${final?.restarts}; exit=${exitReason ?? "none"}`);
  console.log(`recording sizes every 2 s (MB): ${sizes.map((s) => (s / 1e6).toFixed(1)).join(" ")}  → grew in ${grew}/${sizes.length - 1} samples`);
  const cs = cpuStart as { t: number; ticks: Record<string, number> } | null;
  if (cs) {
    const hz = 100;
    const secs = (cpuEnd.t - cs.t) / 1000;
    const pct = (k: string) => (((cpuEnd.ticks[k]! - cs.ticks[k]!) / hz / secs) * 100).toFixed(0);
    console.log(`CPU over last ${secs.toFixed(0)} s: chrome=${pct("chrome")}% ffmpeg=${pct("ffmpeg")}% (of ${os.cpus().length * 100}%)`);
  }
  const recFile = final?.recordingFile ? path.join(dir, final.recordingFile) : null;
  console.log(`\nrecording ${recFile} (${recFile ? (statSync(recFile).size / 1e6).toFixed(1) : "?"} MB, after SIGKILL):\n${recFile ? probe(recFile) : "none"}`);
  console.log(`\nrtmp received ${rtmpOut}:\n${probe(rtmpOut)}`);
}

main().then(
  () => process.exit(0),
  (err) => {
    console.error(err);
    process.exit(1);
  },
);
