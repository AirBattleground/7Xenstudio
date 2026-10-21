/** Tiny logger for the renderer: one readable line per event. Quiet under vitest unless PIPELINE_LOG is set. */
type Level = "debug" | "info" | "warn" | "error";
const ORDER: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };
const min = ORDER[(process.env.LOG_LEVEL as Level) ?? "info"] ?? 20;

function write(level: Level, msg: string, extra?: Record<string, unknown>) {
  if (ORDER[level] < min || (process.env.VITEST && !process.env.PIPELINE_LOG)) return;
  const parts: string[] = [];
  for (const [k, v] of Object.entries(extra ?? {})) {
    const val = v instanceof Error ? v.message : typeof v === "string" ? v : JSON.stringify(v);
    parts.push(`${k}=${val}`);
  }
  const line = `${new Date().toISOString()} ${level.toUpperCase().padEnd(5)} [renderer] ${msg}${parts.length ? "  " + parts.join(" ") : ""}`;
  (level === "error" || level === "warn" ? process.stderr : process.stdout).write(line + "\n");
}

export const log = {
  debug: (msg: string, extra?: Record<string, unknown>) => write("debug", msg, extra),
  info: (msg: string, extra?: Record<string, unknown>) => write("info", msg, extra),
  warn: (msg: string, extra?: Record<string, unknown>) => write("warn", msg, extra),
  error: (msg: string, extra?: Record<string, unknown>) => write("error", msg, extra),
};

/** Lets at most `max` messages through per `windowMs` (noisy page consoles, ffmpeg warnings). */
export function rateLimited(max: number, windowMs: number) {
  let windowStart = 0;
  let count = 0;
  let dropped = 0;
  return (emit: (droppedBefore: number) => void) => {
    const now = Date.now();
    if (now - windowStart > windowMs) {
      windowStart = now;
      count = 0;
    }
    if (count >= max) {
      dropped++;
      return;
    }
    count++;
    emit(dropped);
    dropped = 0;
  };
}
