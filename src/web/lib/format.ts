/** 1.2 GB / 340 MB / 12 KB */
export function formatBytes(n: number): string {
  if (!Number.isFinite(n) || n < 0) return "—";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}

/** h:mm:ss (or m:ss under an hour) */
export function formatDuration(secs: number): string {
  const s = Math.max(0, Math.floor(secs));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const ss = String(s % 60).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${ss}` : `${m}:${ss}`;
}

/** "GPU · NVENC" style label for an ffmpeg encoder name; null when unknown. */
export function encoderLabel(encoder: string | null | undefined): { gpu: boolean; label: string } | null {
  if (!encoder) return null;
  const gpu = encoder !== "libx264" && encoder !== "libopenh264";
  return { gpu, label: gpu ? encoder.replace(/^h264_/, "").toUpperCase() : "CPU" };
}
