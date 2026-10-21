import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

const r = (p: string) => fileURLToPath(new URL(p, import.meta.url));

/** 7XEN Studio web app. Dev: http://localhost:5180 (API proxied to the studio server on :4400). Build → dist/web. */
export default defineConfig({
  root: r("."),
  plugins: [react(), tailwindcss()],
  resolve: { alias: { "@": r("./src/web"), "@shared": r("./src/shared") } },
  build: { outDir: r("./dist/web"), emptyOutDir: true, chunkSizeWarningLimit: 1500 },
  server: {
    port: 5180,
    host: true,
    proxy: { "/api": { target: "http://127.0.0.1:4400", changeOrigin: false } },
  },
});
