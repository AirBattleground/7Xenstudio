import { useEffect, useRef } from "react";
import { STUDIO_HEIGHT, STUDIO_WIDTH, type Scene } from "@shared/types";
import type { StudioMixer } from "@/engine/mixer";
import { cn } from "@/lib/utils";

export function MonitorLabel({ tone, text, sub }: { tone: "live" | "program" | "preview"; text: string; sub?: string }) {
  return (
    <p className="mb-1.5 flex items-center gap-2 text-xs font-bold tracking-[0.2em] uppercase">
      <span className={cn("rounded px-1.5 py-0.5", tone === "live" ? "bg-destructive text-white" : tone === "program" ? "bg-primary/15 text-primary" : "bg-warning/15 text-warning-foreground dark:text-warning")}>{text}</span>
      {sub && <span className="truncate font-semibold tracking-normal text-muted-foreground normal-case">{sub}</span>}
    </p>
  );
}

/** The mixer's own canvas (what this browser draws; the studio PC renders the same scenes for the real output). */
export function ProgramMonitor({ mixer, live }: { mixer: StudioMixer; live: boolean }) {
  const host = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = host.current;
    if (!el) return;
    mixer.canvas.className = "block h-auto w-full";
    el.appendChild(mixer.canvas);
    return () => {
      if (mixer.canvas.parentElement === el) el.removeChild(mixer.canvas);
    };
  }, [mixer]);
  return (
    <div
      ref={host}
      className={cn("overflow-hidden rounded-lg border-2 bg-black", live ? "border-destructive shadow-[0_0_30px_-6px_var(--destructive)]" : "border-primary/40")}
      style={{ aspectRatio: `${STUDIO_WIDTH}/${STUDIO_HEIGHT}` }}
    />
  );
}

export function PreviewMonitor({ mixer, scene }: { mixer: StudioMixer; scene: Scene | null }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    if (scene) void mixer.prepare(scene.slots);
    const c = ref.current;
    if (!c) return;
    const ctx = c.getContext("2d")!;
    const t = window.setInterval(() => {
      ctx.setTransform(c.width / STUDIO_WIDTH, 0, 0, c.height / STUDIO_HEIGHT, 0, 0);
      mixer.drawScene(ctx, scene);
    }, 125);
    return () => window.clearInterval(t);
  }, [mixer, scene]);
  return <canvas ref={ref} width={480} height={270} className="block aspect-video w-full rounded-lg border-2 border-warning/50 bg-black" />;
}
