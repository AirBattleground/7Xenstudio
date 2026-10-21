import { useEffect, useState, type ReactNode } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { Copy, Cpu, KeyRound, Lock, LockOpen, Pencil, Plug, Plus, Radio, Trash2, Youtube } from "lucide-react";
import { toast } from "sonner";
import { DESTINATION_PRESETS, settingsSchema, type Destination } from "@shared/types";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Separator } from "@/components/ui/separator";
import { Skeleton } from "@/components/ui/skeleton";
import { Chip, PageHeader, QueryError } from "@/components/brand";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { StreamKeyDialog } from "@/components/StreamKeyDialog";
import { integrationUi } from "@/integrations/registry";
import { ApiError, errorMessage } from "@/lib/api";
import { encoderLabel } from "@/lib/format";
import { useDeleteDestination, useDestinations, useInfo, useIntegrations, useUpdateDestination, useUpdateSettings } from "@/lib/queries";

export default function SettingsPage() {
  return (
    <>
      <PageHeader title="Settings" description="This studio's name, your stream keys and connections." />
      <div className="grid gap-5 lg:grid-cols-2">
        <StudioCard />
        <SystemCard />
        <StreamKeysCard />
        <ConnectionsCard />
      </div>
    </>
  );
}

function Section({ icon, title, description, children }: { icon: ReactNode; title: string; description?: string; children: ReactNode }) {
  return (
    <Card className="animate-rise">
      <CardHeader>
        <CardTitle className="flex items-center gap-2 font-display text-xl [&_svg]:size-5 [&_svg]:text-primary">
          {icon}
          {title}
        </CardTitle>
        {description && <CardDescription>{description}</CardDescription>}
      </CardHeader>
      <CardContent>{children}</CardContent>
    </Card>
  );
}

function StudioCard() {
  const info = useInfo();
  const update = useUpdateSettings();
  const form = useForm<{ name: string }>({ resolver: zodResolver(settingsSchema.required()), defaultValues: { name: "" } });
  useEffect(() => {
    if (info.data) form.reset({ name: info.data.name });
  }, [info.data, form]);
  const submit = form.handleSubmit((v) =>
    update.mutate(v, {
      onSuccess: () => toast.success("Studio name saved"),
      onError: (e) => {
        if (e instanceof ApiError && e.fields?.name) form.setError("name", { message: e.fields.name });
        else toast.error("Couldn't save", { description: errorMessage(e) });
      },
    }),
  );
  return (
    <Section icon={<Radio />} title="Studio" description="Phones show this name when they connect.">
      {info.isPending ? (
        <Skeleton className="h-20" />
      ) : (
        <form onSubmit={submit} className="space-y-3">
          <div className="space-y-1.5">
            <Label htmlFor="studio-name">Studio name</Label>
            <div className="flex gap-2">
              <Input id="studio-name" className="h-10" {...form.register("name")} aria-invalid={!!form.formState.errors.name} />
              <Button type="submit" className="h-10" disabled={update.isPending || !form.formState.isDirty}>
                Save
              </Button>
            </div>
            {form.formState.errors.name && <p className="text-xs text-destructive">{form.formState.errors.name.message}</p>}
          </div>
        </form>
      )}
    </Section>
  );
}

function CopyRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center gap-2">
      <div className="min-w-0 flex-1">
        <p className="text-xs text-muted-foreground">{label}</p>
        <p className="truncate font-mono text-sm font-semibold">{value}</p>
      </div>
      <Button
        variant="ghost"
        size="icon-sm"
        aria-label={`Copy ${label}`}
        onClick={() =>
          void navigator.clipboard
            ?.writeText(value)
            .then(() => toast.success("Copied"))
            .catch(() => toast.error("Couldn't copy"))
        }
      >
        <Copy />
      </Button>
    </div>
  );
}

function SystemCard() {
  const info = useInfo();
  const d = info.data;
  const enc = encoderLabel(d?.encoder);
  return (
    <Section icon={<Cpu />} title="This PC" description="How phones and other computers on the Wi-Fi reach the studio.">
      {!d ? (
        <Skeleton className="h-32" />
      ) : (
        <div className="space-y-3">
          <CopyRow label="Studio address (open it on any computer on this Wi-Fi)" value={d.lanUrl} />
          <CopyRow label="Media server for phones (RTMP)" value={d.mediaRtmp} />
          <Separator />
          <div className="flex flex-wrap items-center gap-2 text-sm">
            <span className="text-muted-foreground">Video encoder:</span>
            {enc ? (
              <Chip tone={enc.gpu ? "success" : "muted"} title={d.encoder ?? undefined}>
                {enc.gpu ? `GPU · ${enc.label}` : "CPU (no graphics card encoder found)"}
              </Chip>
            ) : (
              <Chip>Checked when the first show starts</Chip>
            )}
          </div>
          <div className="flex flex-wrap items-center gap-2 text-sm">
            <span className="text-muted-foreground">PIN:</span>
            {d.pinRequired ? (
              <Chip tone="success">
                <Lock className="size-3.5" /> On — browsers need the PIN once
              </Chip>
            ) : (
              <Chip tone="warning">
                <LockOpen className="size-3.5" /> Off — anyone on this Wi-Fi can open the studio
              </Chip>
            )}
          </div>
          {!d.pinRequired && <p className="text-xs text-muted-foreground">To add a PIN, set STUDIO_PIN in the studio's .env file and restart it.</p>}
          <p className="text-xs text-muted-foreground">Version {d.version}</p>
        </div>
      )}
    </Section>
  );
}

function StreamKeysCard() {
  const dests = useDestinations();
  const del = useDeleteDestination();
  const [adding, setAdding] = useState(false);
  const [renaming, setRenaming] = useState<Destination | null>(null);
  const [removing, setRemoving] = useState<Destination | null>(null);
  return (
    <Section icon={<KeyRound />} title="Stream keys" description="Where your shows can go live: YouTube, Facebook or any RTMP server.">
      {dests.isError ? (
        <QueryError title="Couldn't load the stream keys" message={errorMessage(dests.error)} onRetry={() => void dests.refetch()} />
      ) : dests.isPending ? (
        <Skeleton className="h-24" />
      ) : (
        <div className="space-y-2">
          {dests.data.length === 0 && <p className="text-sm text-muted-foreground">No stream keys yet. Add one to go live on YouTube or Facebook.</p>}
          {dests.data.map((d) => (
            <div key={d.id} className="flex items-center gap-2 rounded-lg border p-2.5">
              {d.kind === "YOUTUBE" ? <Youtube className="size-5 shrink-0 text-destructive" /> : <Radio className="size-5 shrink-0 text-muted-foreground" />}
              <div className="min-w-0 flex-1">
                <p className="truncate font-semibold">{d.name}</p>
                <p className="truncate text-xs text-muted-foreground">
                  {DESTINATION_PRESETS[d.kind].label} · key ending {d.keyHint}
                </p>
              </div>
              <Button variant="ghost" size="icon-sm" aria-label={`Rename ${d.name}`} onClick={() => setRenaming(d)}>
                <Pencil />
              </Button>
              <Button variant="ghost" size="icon-sm" className="text-muted-foreground hover:text-destructive" aria-label={`Remove ${d.name}`} onClick={() => setRemoving(d)}>
                <Trash2 />
              </Button>
            </div>
          ))}
          <Button variant="outline" className="w-full" onClick={() => setAdding(true)}>
            <Plus /> Add stream key
          </Button>
        </div>
      )}
      <StreamKeyDialog open={adding} onOpenChange={setAdding} />
      <RenameKeyDialog dest={renaming} onClose={() => setRenaming(null)} />
      <ConfirmDialog
        open={!!removing}
        onOpenChange={(o) => !o && setRemoving(null)}
        title={`Remove ${removing?.name ?? "this stream key"}?`}
        description="Shows stop sending there. You can add the key again any time."
        confirmLabel="Remove"
        destructive
        onConfirm={() => removing && del.mutate(removing.id)}
      />
    </Section>
  );
}

function RenameKeyDialog({ dest, onClose }: { dest: Destination | null; onClose: () => void }) {
  const update = useUpdateDestination();
  const [name, setName] = useState("");
  useEffect(() => {
    if (dest) setName(dest.name);
  }, [dest]);
  const valid = name.trim().length >= 2 && name.trim().length <= 40;
  return (
    <Dialog open={!!dest} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="sm:max-w-sm">
        <form
          className="space-y-4"
          onSubmit={(e) => {
            e.preventDefault();
            if (!dest || !valid) return;
            update.mutate(
              { id: dest.id, name: name.trim() },
              { onSuccess: () => (toast.success("Saved"), onClose()), onError: (err) => toast.error("Couldn't save", { description: errorMessage(err) }) },
            );
          }}
        >
          <DialogHeader>
            <DialogTitle>Rename stream key</DialogTitle>
          </DialogHeader>
          <div className="space-y-1.5">
            <Label htmlFor="key-name">Name</Label>
            <Input id="key-name" value={name} onChange={(e) => setName(e.target.value)} autoFocus />
            {!valid && <p className="text-xs text-destructive">2 to 40 characters</p>}
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" disabled={!valid || update.isPending}>
              Save
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

/** Optional connections (integrations) the server offers, each with its own connect UI from the registry. */
function ConnectionsCard() {
  const list = useIntegrations();
  if (list.isError && list.error instanceof ApiError && list.error.status === 404) return null;
  return (
    <Section icon={<Plug />} title="Connections" description="Optional: link this studio to other services.">
      {list.isError ? (
        <QueryError title="Couldn't load connections" message={errorMessage(list.error)} onRetry={() => void list.refetch()} />
      ) : list.isPending ? (
        <Skeleton className="h-16" />
      ) : list.data.length === 0 ? (
        <p className="text-sm text-muted-foreground">No connections available.</p>
      ) : (
        <div className="space-y-4">
          {list.data.map((info, i) => {
            const ui = integrationUi(info.id);
            return (
              <div key={info.id}>
                {i > 0 && <Separator className="mb-4" />}
                {ui ? (
                  <ui.ConnectPanel info={info} />
                ) : (
                  <div className="flex items-center justify-between">
                    <p className="font-semibold">{info.name}</p>
                    <Chip tone={info.connected ? "success" : "muted"}>{info.connected ? "Connected" : "Not connected"}</Chip>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </Section>
  );
}
