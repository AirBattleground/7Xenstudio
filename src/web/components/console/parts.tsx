import type { ReactNode } from "react";
import { STUDIO_HEIGHT, STUDIO_WIDTH, type DeviceRow, type LayoutKind, type Prop, type SourceRef } from "@shared/types";
import { Switch } from "@/components/ui/switch";
import { LAYOUTS } from "@/engine/layouts";
import { cn } from "@/lib/utils";

export function Panel({ title, icon, children, action, ...rest }: { title: string; icon: ReactNode; children: ReactNode; action?: ReactNode; "data-tour"?: string }) {
  return (
    <section className="rounded-xl border bg-card p-3" {...rest}>
      <div className="mb-2 flex items-center justify-between gap-2">
        <h3 className="flex items-center gap-2 text-sm font-bold [&_svg]:size-4 [&_svg]:text-primary">
          {icon}
          {title}
        </h3>
        {action}
      </div>
      {children}
    </section>
  );
}

export function Row({ label, checked, onChange, disabled }: { label: ReactNode; checked: boolean; onChange: (v: boolean) => void; disabled?: boolean }) {
  return (
    <label className={cn("flex min-h-8 items-center justify-between gap-2 text-sm", disabled && "opacity-60")}>
      <span className="min-w-0 truncate">{label}</span>
      <Switch checked={checked} onCheckedChange={onChange} disabled={disabled} />
    </label>
  );
}

export function LayoutIcon({ layout, className }: { layout: LayoutKind; className?: string }) {
  const { rects } = LAYOUTS[layout];
  return (
    <svg viewBox={`0 0 ${STUDIO_WIDTH} ${STUDIO_HEIGHT}`} className={cn("rounded-sm bg-muted", className)} aria-hidden>
      {rects.map((r, i) => (
        <rect key={i} x={r.x} y={r.y} width={r.w} height={r.h} rx={r.framed ? 24 : 0} className={i === 0 ? "fill-primary/60" : "fill-warning/70"} />
      ))}
    </svg>
  );
}

export function sourceLabel(ref: SourceRef | null, devices: DeviceRow[], props: Prop[]): string {
  if (!ref) return "Empty";
  switch (ref.kind) {
    case "device":
      return devices.find((d) => d.id === ref.id)?.name ?? "Removed phone";
    case "prop":
      return props.find((p) => p.id === ref.id)?.name ?? "Removed video";
    case "image":
      return props.find((p) => p.id === ref.id)?.name ?? "Removed image";
    case "camera":
      return "Webcam";
    case "slate":
      return "Slate";
    case "web":
      return "Web image";
  }
}
