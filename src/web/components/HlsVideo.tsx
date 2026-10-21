import { useEffect, useRef, useState } from "react";
import type Hls from "hls.js";
import { cn } from "@/lib/utils";

/** A muted live HLS player (phone preview, program out). Retries when the stream drops. */
export function HlsVideo({ src, className, muted = true, controls = false }: { src: string; className?: string; muted?: boolean; controls?: boolean }) {
  const ref = useRef<HTMLVideoElement>(null);
  const [state, setState] = useState<"loading" | "playing" | "error">("loading");
  useEffect(() => {
    const v = ref.current;
    if (!v) return;
    let hls: Hls | null = null;
    let alive = true;
    let retry: number | null = null;
    setState("loading");
    const onPlaying = () => setState("playing");
    v.addEventListener("playing", onPlaying);
    void import("hls.js").then(({ default: HlsCtor }) => {
      if (!alive) return;
      if (HlsCtor.isSupported()) {
        const h = new HlsCtor({ lowLatencyMode: true, liveSyncDurationCount: 2, xhrSetup: (xhr) => {
          xhr.withCredentials = true;
        } });
        hls = h;
        h.loadSource(src);
        h.attachMedia(v);
        h.on(HlsCtor.Events.MANIFEST_PARSED, () => void v.play().catch(() => undefined));
        h.on(HlsCtor.Events.ERROR, (_e, data) => {
          if (!data.fatal) return;
          setState("error");
          retry = window.setTimeout(() => {
            if (!alive) return;
            h.loadSource(src);
            h.startLoad();
          }, 3000);
        });
      } else {
        v.src = src;
        void v.play().catch(() => undefined);
      }
    });
    return () => {
      alive = false;
      if (retry !== null) window.clearTimeout(retry);
      v.removeEventListener("playing", onPlaying);
      hls?.destroy();
      v.removeAttribute("src");
      v.load();
    };
  }, [src]);
  return (
    <div className={cn("relative overflow-hidden rounded-lg bg-black", className)}>
      <video ref={ref} muted={muted} playsInline controls={controls} className="block size-full object-contain" />
      {state !== "playing" && (
        <div className="absolute inset-0 flex items-center justify-center p-4 text-center text-sm text-white/70">
          {state === "error" ? "No video right now — retrying…" : "Connecting to the video…"}
        </div>
      )}
    </div>
  );
}
