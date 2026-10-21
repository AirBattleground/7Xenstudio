import { useEffect, useState } from "react";
import { AlertTriangle, Film, Loader2 } from "lucide-react";
import type { ShowStatus } from "@shared/types";
import { Chip } from "@/components/brand";
import { encoderLabel, formatDuration } from "@/lib/format";

/** Below this the renderer can't keep up with a 60 fps show (amber). */
const FPS_WARN = 51;

/** Status bar while live: clock, renderer fps, encoder (GPU/CPU), bitrate, per-output health, recording file. */
export function LiveHealth({ status, fps }: { status: ShowStatus | null; fps: 30 | 60 }) {
  const [, setTick] = useState(0);
  useEffect(() => {
    const t = window.setInterval(() => setTick((n) => n + 1), 1000);
    return () => window.clearInterval(t);
  }, []);
  if (!status || status.state !== "LIVE") return null;
  const r = status.renderer;
  const since = status.liveSince ? Date.parse(status.liveSince) : null;
  const secs = since ? (Date.now() - since) / 1000 : 0;
  const warnAt = fps === 60 ? FPS_WARN : Math.round(fps * 0.85);
  const slow = r.fps != null && r.fps < warnAt;
  const enc = encoderLabel(r.encoder);
  return (
    <div className="flex flex-wrap items-center gap-1.5">
      <Chip tone="live">● LIVE {formatDuration(secs)}</Chip>
      {r.state === "starting" && (
        <Chip tone="warning">
          <Loader2 className="size-3 animate-spin" /> Starting…
        </Chip>
      )}
      {r.state === "error" && (
        <Chip tone="danger" title={r.error ?? undefined}>
          <AlertTriangle className="size-3" /> {r.error ?? "The renderer stopped — restarting"}
        </Chip>
      )}
      {r.fps != null && (
        <Chip tone={slow ? "warning" : "muted"} title={slow ? "The studio PC can't keep up. Close other apps on it." : "Frames per second the studio PC is drawing"}>
          <span className="tabular-nums">{Math.round(r.fps)} fps</span>
        </Chip>
      )}
      {enc && (
        <Chip title={`Encoder: ${r.encoder}`}>
          {enc.gpu && <span className="rounded bg-primary px-1 text-[9px] font-bold text-primary-foreground">GPU</span>}
          {enc.label}
        </Chip>
      )}
      {r.bitrateKbps != null && <Chip><span className="tabular-nums">{(r.bitrateKbps / 1000).toFixed(1)} Mbps</span></Chip>}
      {status.outputs
        .filter((o) => o.kind !== "preview")
        .map((o) => (
          <Chip key={o.id} tone={o.ok ? "muted" : "danger"} title={o.error ?? (o.ok ? "Sending" : undefined)}>
            <span className={o.ok ? "size-1.5 rounded-full bg-success" : "size-1.5 rounded-full bg-destructive"} />
            {o.name}
            {!o.ok && o.error ? `: ${o.error}` : ""}
          </Chip>
        ))}
      {status.recordingFile && (
        <Chip title={status.recordingFile}>
          <Film className="size-3" /> <span className="max-w-48 truncate">{status.recordingFile}</span>
        </Chip>
      )}
    </div>
  );
}
