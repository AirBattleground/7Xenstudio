import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const r = (p: string) => fileURLToPath(new URL(p, import.meta.url));

/** Unit tests: tests/*.test.ts in a node environment (pure helpers; no browser APIs). */
export default defineConfig({
  resolve: { alias: { "@": r("./src/web"), "@shared": r("./src/shared") } },
  test: { environment: "node", include: ["tests/**/*.test.ts"] },
});
