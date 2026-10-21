import { useState } from "react";
import { formatDistanceToNow, parseISO } from "date-fns";
import { BatteryCharging, BatteryFull, BatteryLow, BatteryMedium, Eye, MoreVertical, Pencil, Plus, Smartphone, Thermometer, Trash2, Wifi } from "lucide-react";
import type { DeviceRow } from "@shared/types";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Skeleton } from "@/components/ui/skeleton";
import { AddPhoneDialog } from "@/components/AddPhoneDialog";
import { Chip, EmptyState, PageHeader, QueryError } from "@/components/brand";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { HlsVideo } from "@/components/HlsVideo";
import { errorMessage } from "@/lib/api";
import { useDeleteDevice, useDevices, useRenameDevice } from "@/lib/queries";

export default function PhonesPage() {
  const devices = useDevices({ poll: 3_000 });
  const [adding, setAdding] = useState(false);
  const [renaming, setRenaming] = useState<DeviceRow | null>(null);
  const [removing, setRemoving] = useState<DeviceRow | null>(null);
  const [watching, setWatching] = useState<DeviceRow | null>(null);
  const del = useDeleteDevice();

  return (
    <>
      <PageHeader
        title="Phones"
        description="Phones with the 7XEN Stream app send their camera or screen to this PC over Wi-Fi."
        actions={
          <Button size="lg" onClick={() => setAdding(true)}>
            <Plus /> Add phone
          </Button>
        }
      />
      {devices.isError ? (
        <QueryError title="Couldn't load your phones" message={errorMessage(devices.error)} onRetry={() => void devices.refetch()} />
      ) : devices.isPending ? (
        <div className="space-y-2">
          {[0, 1, 2].map((i) => (
            <Skeleton key={i} className="h-20 rounded-xl" />
          ))}
        </div>
      ) : devices.data.length === 0 ? (
        <EmptyState
          icon={<Smartphone />}
          title="No phones yet"
          description="Add a phone, then scan the QR code with the 7XEN Stream app. The phone must be on the same Wi-Fi as this PC."
          action={
            <Button size="lg" onClick={() => setAdding(true)}>
              <Plus /> Add your first phone
            </Button>
          }
        />
      ) : (
        <ul className="space-y-2">
          {devices.data.map((d) => (
            <PhoneRow key={d.id} d={d} onWatch={() => setWatching(d)} onRename={() => setRenaming(d)} onRemove={() => setRemoving(d)} />
          ))}
        </ul>
      )}

      <AddPhoneDialog open={adding} onOpenChange={setAdding} />
      <RenameDialog device={renaming} onClose={() => setRenaming(null)} />
      <ConfirmDialog
        open={!!removing}
        onOpenChange={(o) => !o && setRemoving(null)}
        title={`Remove ${removing?.name ?? "this phone"}?`}
        description="It can't stream to this studio any more. To use it again, add it again and scan the new QR code."
        confirmLabel="Remove phone"
        destructive
        onConfirm={() => removing && del.mutate(removing.id)}
      />
      <Dialog open={!!watching} onOpenChange={(o) => !o && setWatching(null)}>
        <DialogContent className="sm:max-w-3xl">
          <DialogHeader>
            <DialogTitle>{watching?.name}</DialogTitle>
            <DialogDescription>Live from the phone (a second or two behind).</DialogDescription>
          </DialogHeader>
          {watching && <HlsVideo src={watching.hlsUrl} className="aspect-video w-full" />}
        </DialogContent>
      </Dialog>
    </>
  );
}

function BatteryIcon({ level, charging }: { level: number; charging?: boolean }) {
  if (charging) return <BatteryCharging className="size-4" />;
  if (level < 0.2) return <BatteryLow className="size-4" />;
  if (level < 0.6) return <BatteryMedium className="size-4" />;
  return <BatteryFull className="size-4" />;
}

const THERMAL: Record<string, { label: string; tone: "success" | "warning" | "danger" | "muted" }> = {
  nominal: { label: "Cool", tone: "success" },
  fair: { label: "Warm", tone: "muted" },
  serious: { label: "Hot", tone: "warning" },
  critical: { label: "Too hot", tone: "danger" },
};

function PhoneRow({ d, onWatch, onRename, onRemove }: { d: DeviceRow; onWatch: () => void; onRename: () => void; onRemove: () => void }) {
  const h = d.health;
  const thermal = h?.thermal ? THERMAL[h.thermal] : null;
  return (
    <li className="flex animate-rise flex-wrap items-center gap-3 rounded-xl border bg-card p-3 sm:p-4">
      <div className="flex size-11 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary">
        <Smartphone className="size-5" />
      </div>
      <div className="min-w-0 flex-1">
        <p className="truncate font-display text-lg font-bold">{d.name}</p>
        <p className="truncate text-xs text-muted-foreground">
          {[d.model, d.osVersion && `iOS ${d.osVersion}`].filter(Boolean).join(" · ") || "Not connected yet"}
          {!d.online && d.lastSeenAt && ` · last seen ${formatDistanceToNow(parseISO(d.lastSeenAt), { addSuffix: true })}`}
        </p>
      </div>
      <div className="flex flex-wrap items-center gap-1.5">
        {d.streaming ? (
          <Chip tone="live">● Streaming</Chip>
        ) : d.online ? (
          <Chip tone="success">Online</Chip>
        ) : (
          <Chip>Offline</Chip>
        )}
        {h?.battery != null && (
          <Chip tone={h.battery < 0.2 && !h.charging ? "danger" : "muted"} title="Battery">
            <BatteryIcon level={h.battery} charging={h.charging} /> {Math.round(h.battery * 100)}%
          </Chip>
        )}
        {thermal && (
          <Chip tone={thermal.tone} title="Phone temperature">
            <Thermometer className="size-3.5" /> {thermal.label}
          </Chip>
        )}
        {d.streaming && h?.fps != null && <Chip title="Frames per second from the phone">{Math.round(h.fps)} fps</Chip>}
        {d.streaming && h?.quality && <Chip>{h.quality}</Chip>}
        {h?.network === "wifi" && d.online && (
          <Chip title="On Wi-Fi">
            <Wifi className="size-3.5" />
          </Chip>
        )}
      </div>
      <div className="flex items-center gap-1">
        <Button variant="outline" size="sm" onClick={onWatch} disabled={!d.videoReady}>
          <Eye /> Watch
        </Button>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" size="icon-sm" aria-label={`More for ${d.name}`}>
              <MoreVertical />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem onClick={onRename}>
              <Pencil /> Rename
            </DropdownMenuItem>
            <DropdownMenuItem variant="destructive" onClick={onRemove}>
              <Trash2 /> Remove
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </li>
  );
}

function RenameDialog({ device, onClose }: { device: DeviceRow | null; onClose: () => void }) {
  const rename = useRenameDevice();
  const [name, setName] = useState("");
  const [lastId, setLastId] = useState<string | null>(null);
  if (device && device.id !== lastId) {
    setLastId(device.id);
    setName(device.name);
  }
  const valid = name.trim().length >= 2 && name.trim().length <= 40;
  return (
    <Dialog open={!!device} onOpenChange={(o) => !o && (onClose(), setLastId(null))}>
      <DialogContent className="sm:max-w-sm">
        <form
          className="space-y-4"
          onSubmit={(e) => {
            e.preventDefault();
            if (!device || !valid) return;
            rename.mutate({ id: device.id, name: name.trim() }, { onSuccess: () => (onClose(), setLastId(null)) });
          }}
        >
          <DialogHeader>
            <DialogTitle>Rename phone</DialogTitle>
          </DialogHeader>
          <div className="space-y-1.5">
            <Label htmlFor="rename">Name</Label>
            <Input id="rename" value={name} onChange={(e) => setName(e.target.value)} autoFocus className="h-11 text-base" />
            {!valid && <p className="text-xs text-destructive">2 to 40 characters</p>}
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" disabled={!valid || rename.isPending}>
              Save
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
