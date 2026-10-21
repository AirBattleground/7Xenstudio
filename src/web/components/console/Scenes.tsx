import { useEffect, useState } from "react";
import { Check, Pencil, Trash2 } from "lucide-react";
import type { DeviceRow, LayoutKind, Prop, Scene, SourceRef } from "@shared/types";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectGroup, SelectItem, SelectLabel, SelectTrigger, SelectValue } from "@/components/ui/select";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { LAYOUTS } from "@/engine/layouts";
import { cn } from "@/lib/utils";
import { LayoutIcon, sourceLabel } from "./parts";

export function SceneCard(props: { scene: Scene; index: number; devices: DeviceRow[]; props: Prop[]; onAir: boolean; selected: boolean; onSelect: () => void; onTake: () => void; onEdit: () => void }) {
  const { scene, index, onAir, selected } = props;
  return (
    <div
      role="button"
      tabIndex={0}
      onClick={props.onSelect}
      onDoubleClick={props.onTake}
      onKeyDown={(e) => e.key === "Enter" && props.onTake()}
      className={cn(
        "group relative cursor-pointer rounded-lg border bg-background/60 p-2 transition-all outline-none hover:border-primary/50 focus-visible:ring-[3px] focus-visible:ring-ring/50",
        selected && "border-warning ring-1 ring-warning/50",
        onAir && "border-destructive ring-2 ring-destructive/60",
      )}
    >
      <LayoutIcon layout={scene.layout} className="aspect-video w-full" />
      <div className="mt-1.5 flex items-center gap-1.5">
        {index < 9 && <span className="rounded bg-muted px-1.5 font-mono text-xs font-bold">{index + 1}</span>}
        <span className="min-w-0 flex-1 truncate text-sm font-semibold">{scene.name}</span>
        {onAir && <span className="rounded bg-destructive px-1 text-[10px] font-bold text-white">ON AIR</span>}
      </div>
      <p className="truncate text-xs text-muted-foreground">{scene.slots.map((s) => sourceLabel(s, props.devices, props.props)).join(" · ")}</p>
      <button
        type="button"
        aria-label={`Edit ${scene.name}`}
        onClick={(e) => (e.stopPropagation(), props.onEdit())}
        className="absolute top-3 right-3 rounded-md bg-background/90 p-1.5 opacity-70 transition-opacity group-hover:opacity-100 focus:opacity-100"
      >
        <Pencil className="size-3.5" />
      </button>
    </div>
  );
}

const SLOT_NONE = "none";

/** "kind:id" (url for web sources) ↔ SourceRef. */
export function refToValue(r: SourceRef | null): string {
  if (!r) return SLOT_NONE;
  if (r.kind === "web") return "web:";
  return `${r.kind}:${"id" in r ? r.id : ""}`;
}
export function valueToRef(v: string, webUrl: string): SourceRef | null {
  if (v === SLOT_NONE) return null;
  const i = v.indexOf(":");
  const kind = (i >= 0 ? v.slice(0, i) : v) as SourceRef["kind"];
  const id = i >= 0 ? v.slice(i + 1) : "";
  switch (kind) {
    case "device":
    case "prop":
    case "image":
      return { kind, id };
    case "web":
      return { kind: "web", url: webUrl };
    case "camera":
      return { kind: "camera" };
    default:
      return { kind: "slate" };
  }
}

const isHttpUrl = (u: string) => {
  try {
    const x = new URL(u);
    return x.protocol === "http:" || x.protocol === "https:";
  } catch {
    return false;
  }
};

export function SceneEditor({
  scene,
  devices,
  props,
  onClose,
  onSave,
  onDelete,
  canDelete,
}: {
  scene: Scene | null;
  devices: DeviceRow[];
  props: Prop[];
  onClose: () => void;
  onSave: (s: Scene) => void;
  onDelete: (s: Scene) => void;
  canDelete: boolean;
}) {
  const [draft, setDraft] = useState<Scene | null>(scene);
  const [confirmDelete, setConfirmDelete] = useState(false);
  useEffect(() => setDraft(scene), [scene]);
  if (!draft) return null;
  const lay = LAYOUTS[draft.layout];
  const videos = props.filter((p) => p.kind === "video");
  const images = props.filter((p) => p.kind === "image");
  const badWeb = draft.slots.some((s) => s?.kind === "web" && !isHttpUrl(s.url));
  const setSlot = (i: number, ref: SourceRef | null) => setDraft({ ...draft, slots: Array.from({ length: lay.slots }, (_, j) => (j === i ? ref : (draft.slots[j] ?? null))) });

  return (
    <Dialog open={!!scene} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-h-[90dvh] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Edit scene</DialogTitle>
          <DialogDescription>Pick a frame, then what goes in each part of it.</DialogDescription>
        </DialogHeader>
        <div className="grid gap-4">
          <div className="grid gap-1.5">
            <Label htmlFor="scene-name">Scene name</Label>
            <Input id="scene-name" value={draft.name} maxLength={40} onChange={(e) => setDraft({ ...draft, name: e.target.value })} />
          </div>
          <div className="grid gap-1.5">
            <Label>Frame</Label>
            <div className="grid grid-cols-3 gap-2 sm:grid-cols-5">
              {(Object.keys(LAYOUTS) as LayoutKind[]).map((k) => (
                <button
                  key={k}
                  type="button"
                  onClick={() => setDraft({ ...draft, layout: k, slots: Array.from({ length: LAYOUTS[k].slots }, (_, i) => draft.slots[i] ?? null) })}
                  className={cn("rounded-md border p-1 text-xs font-semibold", draft.layout === k ? "border-primary ring-1 ring-primary" : "hover:border-primary/50")}
                  title={LAYOUTS[k].label}
                >
                  <LayoutIcon layout={k} className="aspect-video w-full" />
                  <span className="mt-1 block truncate">{LAYOUTS[k].label}</span>
                </button>
              ))}
            </div>
          </div>
          {lay.slotNames.map((name, i) => {
            const ref = draft.slots[i] ?? null;
            return (
              <div key={name} className="grid gap-1.5">
                <Label>{name}</Label>
                <Select value={refToValue(ref)} onValueChange={(v) => setSlot(i, valueToRef(v, ref?.kind === "web" ? ref.url : ""))}>
                  <SelectTrigger className="w-full">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value={SLOT_NONE}>Empty</SelectItem>
                    {devices.length > 0 && (
                      <SelectGroup>
                        <SelectLabel>Phones</SelectLabel>
                        {devices.map((d) => (
                          <SelectItem key={d.id} value={`device:${d.id}`}>
                            {d.name}
                          </SelectItem>
                        ))}
                      </SelectGroup>
                    )}
                    <SelectGroup>
                      <SelectLabel>This computer</SelectLabel>
                      <SelectItem value="camera:">Webcam (preview only)</SelectItem>
                      <SelectItem value="slate:">Slate (text, or the intro video)</SelectItem>
                    </SelectGroup>
                    {videos.length > 0 && (
                      <SelectGroup>
                        <SelectLabel>Videos</SelectLabel>
                        {videos.map((p) => (
                          <SelectItem key={p.id} value={`prop:${p.id}`}>
                            {p.name}
                          </SelectItem>
                        ))}
                      </SelectGroup>
                    )}
                    {images.length > 0 && (
                      <SelectGroup>
                        <SelectLabel>Images</SelectLabel>
                        {images.map((p) => (
                          <SelectItem key={p.id} value={`image:${p.id}`}>
                            {p.name}
                          </SelectItem>
                        ))}
                      </SelectGroup>
                    )}
                    <SelectGroup>
                      <SelectLabel>Web</SelectLabel>
                      <SelectItem value="web:">Image from a web address</SelectItem>
                    </SelectGroup>
                  </SelectContent>
                </Select>
                {ref?.kind === "web" && (
                  <>
                    <Input value={ref.url} onChange={(e) => setSlot(i, { kind: "web", url: e.target.value.trim() })} placeholder="https://… (an image that updates, e.g. a scoreboard PNG)" aria-invalid={!isHttpUrl(ref.url)} />
                    <p className="text-xs text-muted-foreground">Refreshed every 2 seconds. It must be an image (PNG, JPG, SVG, GIF), not a web page.</p>
                  </>
                )}
                {ref?.kind === "camera" && <p className="text-xs text-muted-foreground">The studio PC has no webcam: the real output shows the slate here.</p>}
              </div>
            );
          })}
        </div>
        <DialogFooter className="gap-2 sm:justify-between">
          <Button variant="ghost" className="text-destructive" disabled={!canDelete} onClick={() => setConfirmDelete(true)}>
            <Trash2 /> Delete scene
          </Button>
          <Button disabled={badWeb} onClick={() => onSave({ ...draft, name: draft.name.trim() || "Scene" })}>
            <Check /> Save scene
          </Button>
        </DialogFooter>
        <ConfirmDialog
          open={confirmDelete}
          onOpenChange={setConfirmDelete}
          title={`Delete ${draft.name || "this scene"}?`}
          description="The scene is removed from this show."
          confirmLabel="Delete scene"
          destructive
          onConfirm={() => onDelete(draft)}
        />
      </DialogContent>
    </Dialog>
  );
}
