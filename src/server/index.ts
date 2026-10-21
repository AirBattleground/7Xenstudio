/**
 * 7XEN Studio: live production on a venue PC. Phones publish to the local MediaMTX, the web app builds scenes, and
 * the renderer pipeline records / streams the finished show.
 */
import http from "node:http";
import { createStudio } from "./app.js";
import { loadConfig } from "./config.js";
import { detectEncoder, detectedEncoder, startPipeline } from "./pipeline/index.js";

const log = (msg: string) => console.log(`${new Date().toISOString()} ${msg}`);

const cfg = loadConfig();
const studio = createStudio(cfg, { startPipeline, detectedEncoder, log });

const server = http.createServer(studio.handler);
// control long-polls wait up to 25 s; uploads can be big and slow
server.requestTimeout = 0;
server.headersTimeout = 30_000;
server.keepAliveTimeout = 65_000;

server.listen(cfg.port, "0.0.0.0", () => {
  log(`7XEN Studio "${studio.info(true).name}" on ${cfg.lanUrl}  (data ${cfg.dataDir})`);
  log(`media: RTMP rtmp://${cfg.lanHost}:${cfg.mediaRtmpPort}/live · HLS ${cfg.mediaHlsUrl} · API ${cfg.mediaApiUrl}`);
  log(`web app: ${cfg.webDist}`);
  log(cfg.pin ? "PIN: on (the web app asks for STUDIO_PIN)" : "PIN: off (anyone on this network can use the studio)");
  detectEncoder({ ffmpegPath: cfg.ffmpegPath, override: cfg.encoder }).then(
    (e) => log(`encoder: ${e}`),
    (e) => log(`encoder: detection failed (${e instanceof Error ? e.message : e}); is ffmpeg installed? Set FFMPEG_PATH`),
  );
});

let closing = false;
const shutdown = (signal: string) => {
  if (closing) return;
  closing = true;
  log(`${signal}: shutting down`);
  server.close();
  server.closeAllConnections?.();
  const t = setTimeout(() => process.exit(0), 8000);
  t.unref();
  studio.integrations.dispose();
  studio.shows.stopAll().finally(() => process.exit(0));
};
process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
