import { useRef, useState } from "react";
import { Camera, CameraOff, Film, Headphones, ImageIcon, Layers, Loader2, Plus, Radio, Smartphone, Trash2, Upload, Youtube } from "lucide-react";
import type { Destination, DeviceRow, Prop, ShowConfig, ShowOutputs } from "@shared/types";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { AddPhoneDialog } from "@/components/AddPhoneDialog";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { StreamKeyDialog } from "@/components/StreamKeyDialog";
import type { StudioMixer } from "@/engine/mixer";
import { formatBytes } from "@/lib/format";
import { useDeleteDestination, useDeleteProp, useUploadProp } from "@/lib/queries";
import { cn } from "@/lib/utils";
import { Panel, Row } from "./parts";

type SetConfig = React.Dispatch<React.SetStateAction<ShowConfig>>;

// ---------------------------------------------------------------- sources

export function SourcesPanel({ mixer, devices, props, config, setConfig }: { mixer: StudioMixer; devices: DeviceRow[]; props: Prop[]; config: ShowConfig; setConfig: SetConfig }) {
  const [adding, setAdding] = useState(false);
  const [monitor, setMonitor] = useState(false);
  const [camOn, setCamOn] = useState(false);
  const [removing, setRemoving] = useState<Prop | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const upload = useUploadProp();
  const delProp = useDeleteProp();

  return (
    <aside data-tour="studio-sources" className="flex flex-col gap-3">
      <Panel
        title="Phones"
        icon={<Smartphone />}
        action={
          <Button size="xs" variant="outline" onClick={() => setAdding(true)}>
            <Plus /> Add
          </Button>
        }
      >
        {devices.length === 0 && <p className="text-xs text-muted-foreground">No phones yet. Tap Add, then scan the QR code with the 7XEN Stream app.</p>}
        <ul className="space-y-1.5">
          {devices.map((d) => (
            <li key={d.id} className="flex items-center gap-2 text-sm">
              <span className={cn("size-2 shrink-0 rounded-full", d.videoReady ? "bg-success" : d.online ? "bg-warning" : "bg-muted-foreground/40")} />
              <span className="min-w-0 flex-1 truncate">{d.name}</span>
              <span className="text-xs text-muted-foreground">{d.videoReady ? "live" : d.online ? "online" : "off"}</span>
            </li>
          ))}
        </ul>
        <AddPhoneDialog open={adding} onOpenChange={setAdding} />
      </Panel>

      <Panel title="This computer" icon={<Camera />}>
        <div className="space-y-2">
          <label className="flex min-h-8 items-center justify-between text-sm">
            <span className="flex items-center gap-1.5">
              {camOn ? <Camera className="size-4" /> : <CameraOff className="size-4" />} Webcam
            </span>
            <Switch
              checked={camOn}
              onCheckedChange={(on) => {
                setCamOn(on);
                if (on) void mixer.prepare([{ kind: "camera" }]);
                else mixer.release({ kind: "camera" });
              }}
            />
          </label>
          <label className="flex min-h-8 items-center justify-between text-sm">
            <span className="flex items-center gap-1.5">
              <Headphones className="size-4" /> Hear the sound here
            </span>
            <Switch checked={monitor} onCheckedChange={(on) => (mixer.setMonitor(on), setMonitor(on))} />
          </label>
          <p className="text-xs text-muted-foreground">The webcam shows in this preview only. The finished show is made on the studio PC.</p>
        </div>
      </Panel>

      <Panel title="Videos & images" icon={<Film />}>
        <input
          ref={fileRef}
          type="file"
          accept="video/*,image/*"
          className="hidden"
          onChange={(e) => {
            const f = e.target.files?.[0];
            e.target.value = "";
            if (f) upload.mutate(f);
          }}
        />
        <Button size="sm" variant="outline" className="w-full" disabled={upload.isPending} onClick={() => fileRef.current?.click()}>
          {upload.isPending ? <Loader2 className="animate-spin" /> : <Upload />} {upload.isPending ? "Uploading…" : "Add video or image"}
        </Button>
        <ul className="mt-2 space-y-1.5">
          {props.map((p) => {
            const isIntro = config.introPropId === p.id;
            const isLogo = config.overlays.logo.propId === p.id && config.overlays.logo.on;
            return (
              <li key={p.id} className="flex items-center gap-2 text-sm">
                {p.kind === "video" ? <Film className="size-3.5 shrink-0 text-muted-foreground" /> : <ImageIcon className="size-3.5 shrink-0 text-muted-foreground" />}
                <span className="min-w-0 flex-1 truncate" title={`${p.name} · ${formatBytes(p.sizeBytes)}`}>
                  {p.name}
                </span>
                {p.kind === "video" ? (
                  <button
                    type="button"
                    title="Play on the slate scenes (Starting soon, Break)"
                    onClick={() => setConfig((c) => ({ ...c, introPropId: c.introPropId === p.id ? null : p.id }))}
                    className={cn("rounded px-1.5 py-0.5 text-[10px] font-bold", isIntro ? "bg-primary text-primary-foreground" : "bg-muted text-muted-foreground")}
                  >
                    INTRO
                  </button>
                ) : (
                  <button
                    type="button"
                    title="Show as the logo in a corner"
                    onClick={() => setConfig((c) => ({ ...c, overlays: { ...c.overlays, logo: { ...c.overlays.logo, on: !isLogo, propId: p.id } } }))}
                    className={cn("rounded px-1.5 py-0.5 text-[10px] font-bold", isLogo ? "bg-primary text-primary-foreground" : "bg-muted text-muted-foreground")}
                  >
                    LOGO
                  </button>
                )}
                <button type="button" aria-label={`Remove ${p.name}`} onClick={() => setRemoving(p)} className="text-muted-foreground hover:text-destructive">
                  <Trash2 className="size-3.5" />
                </button>
              </li>
            );
          })}
        </ul>
        <p className="mt-2 text-xs text-muted-foreground">Tag a video as INTRO to loop it on the slate. Use images in scenes or as the logo.</p>
        <ConfirmDialog
          open={!!removing}
          onOpenChange={(o) => !o && setRemoving(null)}
          title={`Remove ${removing?.name ?? "this file"}?`}
          description="Scenes that use it show an empty slot instead."
          confirmLabel="Remove"
          destructive
          onConfirm={() => {
            const p = removing;
            if (!p) return;
            delProp.mutate(p.id, {
              onSuccess: () => {
                mixer.release(p.kind === "video" ? { kind: "prop", id: p.id } : { kind: "image", id: p.id });
                setConfig((c) => ({
                  ...c,
                  introPropId: c.introPropId === p.id ? null : c.introPropId,
                  overlays: c.overlays.logo.propId === p.id ? { ...c.overlays, logo: { ...c.overlays.logo, on: false, propId: null } } : c.overlays,
                }));
              },
            });
          }}
        />
      </Panel>
    </aside>
  );
}

// ---------------------------------------------------------------- overlays

const CORNERS = [
  { v: "tl", label: "Top left" },
  { v: "tr", label: "Top right" },
  { v: "bl", label: "Bottom left" },
  { v: "br", label: "Bottom right" },
] as const;

export function OverlaysPanel({ config, setConfig, props }: { config: ShowConfig; setConfig: SetConfig; props: Prop[] }) {
  const o = config.overlays;
  const set = (patch: Partial<ShowConfig["overlays"]>) => setConfig((c) => ({ ...c, overlays: { ...c.overlays, ...patch } }));
  const images = props.filter((p) => p.kind === "image");
  return (
    <Panel title="Overlays" icon={<Layers />} data-tour="studio-overlays">
      <div className="space-y-2.5">
        <Row label="LIVE bug + clock" checked={o.liveBug} onChange={(v) => set({ liveBug: v })} />
        <Row label="Lower third (name strip)" checked={o.lowerThird} onChange={(v) => set({ lowerThird: v })} />
        {o.lowerThird && (
          <div className="grid gap-1.5 pl-1">
            <Input value={o.lowerTitle} maxLength={80} onChange={(e) => set({ lowerTitle: e.target.value })} placeholder="Name, e.g. Alex" className="h-8 text-sm" />
            <Input value={o.lowerSubtitle} maxLength={80} onChange={(e) => set({ lowerSubtitle: e.target.value })} placeholder="Role, e.g. Caster" className="h-8 text-sm" />
          </div>
        )}
        <Row label="Ticker (scrolling text)" checked={o.ticker} onChange={(v) => set({ ticker: v })} />
        {o.ticker && <Input value={o.tickerText} maxLength={500} onChange={(e) => set({ tickerText: e.target.value })} placeholder="e.g. Next match at 9 PM · Follow us on Instagram" className="h-8 text-sm" />}
        <Row label="Logo" checked={o.logo.on} disabled={!images.length} onChange={(v) => set({ logo: { ...o.logo, on: v, propId: o.logo.propId ?? images[0]?.id ?? null } })} />
        {!images.length && <p className="-mt-1 text-xs text-muted-foreground">Add an image under Videos & images to use it as a logo.</p>}
        {o.logo.on && images.length > 0 && (
          <div className="grid grid-cols-2 gap-1.5 pl-1">
            <Select value={o.logo.propId ?? ""} onValueChange={(v) => set({ logo: { ...o.logo, propId: v } })}>
              <SelectTrigger size="sm" className="w-full text-xs">
                <SelectValue placeholder="Pick an image" />
              </SelectTrigger>
              <SelectContent>
                {images.map((p) => (
                  <SelectItem key={p.id} value={p.id}>
                    {p.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Select value={o.logo.corner} onValueChange={(v) => set({ logo: { ...o.logo, corner: v as typeof o.logo.corner } })}>
              <SelectTrigger size="sm" className="w-full text-xs">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {CORNERS.map((c) => (
                  <SelectItem key={c.v} value={c.v}>
                    {c.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        )}
        <Row label="Web overlay (image URL)" checked={o.web.on} onChange={(v) => set({ web: { ...o.web, on: v } })} />
        {o.web.on && (
          <div className="grid gap-1 pl-1">
            <Input value={o.web.url} maxLength={500} onChange={(e) => set({ web: { ...o.web, url: e.target.value.trim() } })} placeholder="https://… scoreboard.png" className="h-8 text-sm" />
            <p className="text-xs text-muted-foreground">A transparent image that updates (e.g. a scoreboard PNG), drawn over the whole picture and refreshed every 2 s.</p>
          </div>
        )}
        <div className="grid gap-1 pt-1">
          <span className="text-sm">Slate text</span>
          <Input value={o.slateText} maxLength={80} onChange={(e) => set({ slateText: e.target.value })} placeholder="Starting soon" className="h-8 text-sm" />
        </div>
      </div>
    </Panel>
  );
}

// ---------------------------------------------------------------- outputs

export function OutputsPanel({
  outputs,
  setOutputs,
  destinations,
  live,
  extra,
}: {
  outputs: ShowOutputs;
  setOutputs: (o: ShowOutputs) => void;
  destinations: Destination[];
  live: boolean;
  /** integration output groups (from the registry) */
  extra?: React.ReactNode;
}) {
  const [adding, setAdding] = useState(false);
  const [removing, setRemoving] = useState<Destination | null>(null);
  const del = useDeleteDestination();
  const toggleDest = (id: string, v: boolean) => setOutputs({ ...outputs, destinationIds: v ? [...outputs.destinationIds.filter((x) => x !== id), id] : outputs.destinationIds.filter((x) => x !== id) });
  return (
    <Panel title="Outputs" icon={<Radio />} data-tour="studio-outputs">
      <div className="space-y-2.5">
        <Row label={<span className="font-semibold">Record on this PC</span>} checked={outputs.record} disabled={live} onChange={(v) => setOutputs({ ...outputs, record: v })} />
        {destinations.map((d) => (
          <div key={d.id} className="flex items-center gap-1">
            <div className="min-w-0 flex-1">
              <Row
                label={
                  <span className="flex items-center gap-1.5">
                    {d.kind === "YOUTUBE" && <Youtube className="size-4 text-destructive" />} {d.name}
                  </span>
                }
                checked={outputs.destinationIds.includes(d.id)}
                disabled={live}
                onChange={(v) => toggleDest(d.id, v)}
              />
            </div>
            {!live && (
              <Button size="icon-sm" variant="ghost" className="text-muted-foreground hover:text-destructive" aria-label={`Remove ${d.name}`} onClick={() => setRemoving(d)}>
                <Trash2 />
              </Button>
            )}
          </div>
        ))}
        {!live && (
          <Button size="sm" variant="outline" className="w-full" onClick={() => setAdding(true)}>
            <Plus /> Add stream key
          </Button>
        )}
        {extra}
        {live && <p className="text-xs text-muted-foreground">End the show to change outputs.</p>}
      </div>
      <StreamKeyDialog open={adding} onOpenChange={setAdding} onAdded={(id) => toggleDest(id, true)} />
      <ConfirmDialog
        open={!!removing}
        onOpenChange={(v) => !v && setRemoving(null)}
        title={`Remove ${removing?.name ?? "this stream key"}?`}
        description="The studio stops sending shows there. You can add the key again any time."
        confirmLabel="Remove"
        destructive
        onConfirm={() => {
          const d = removing;
          if (!d) return;
          del.mutate(d.id, { onSuccess: () => toggleDest(d.id, false) });
        }}
      />
    </Panel>
  );
}

// ---------------------------------------------------------------- transition

export function TransitionToggle({ value, onChange }: { value: "cut" | "fade"; onChange: (v: "cut" | "fade") => void }) {
  return (
    <ToggleGroup type="single" variant="outline" size="sm" value={value} onValueChange={(v) => v && onChange(v as "cut" | "fade")}>
      <ToggleGroupItem value="cut" className="px-3">
        Cut
      </ToggleGroupItem>
      <ToggleGroupItem value="fade" className="px-3">
        Fade
      </ToggleGroupItem>
    </ToggleGroup>
  );
}
