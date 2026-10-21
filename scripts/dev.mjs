#!/usr/bin/env node
/**
 * pnpm dev: the studio server (tsx watch, :4400) + the vite dev server (:5180, proxies /api to :4400).
 * Ctrl+C stops both. Start the media server separately: `docker compose up -d`.
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bin = (name) => path.join(root, "node_modules", ".bin", process.platform === "win32" ? `${name}.cmd` : name);

const procs = [];
function run(label, cmd, args) {
  const p = spawn(cmd, args, { cwd: root, stdio: ["inherit", "pipe", "pipe"], env: process.env, shell: process.platform === "win32" });
  const prefix = (stream, out) => {
    let buf = "";
    stream.on("data", (c) => {
      buf += c;
      const lines = buf.split("\n");
      buf = lines.pop() ?? "";
      for (const l of lines) out.write(`[${label}] ${l}\n`);
    });
  };
  prefix(p.stdout, process.stdout);
  prefix(p.stderr, process.stderr);
  p.on("exit", (code, signal) => {
    console.log(`[${label}] exited (${signal ?? code})`);
    shutdown(code ?? 0);
  });
  procs.push(p);
}

let down = false;
function shutdown(code) {
  if (down) return;
  down = true;
  for (const p of procs) if (p.exitCode === null) p.kill("SIGTERM");
  setTimeout(() => process.exit(code), 1500).unref();
}
process.on("SIGINT", () => shutdown(0));
process.on("SIGTERM", () => shutdown(0));

const envFile = existsSync(path.join(root, ".env")) ? ["--env-file=.env"] : [];
run("server", bin("tsx"), ["watch", ...envFile, "src/server/index.ts"]);
run("web", bin("vite"), []);
