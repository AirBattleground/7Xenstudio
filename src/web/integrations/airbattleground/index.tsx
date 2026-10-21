/**
 * AirBattleground integration (web UI): connect by QR, link a show to a match, extra outputs (Live page, site
 * YouTube, the manager's stream keys) and Team list / Results captures. Talks only to the studio server's generic
 * /api/integrations/airbattleground/* routes.
 */
import { useEffect, useState } from "react";
import { ListOrdered, Loader2, Plug, Trophy, Unplug, Youtube } from "lucide-react";
import { toast } from "sonner";
import type { CaptureKind, IntegrationInfo, IntegrationOutput, ShowLink } from "@shared/types";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { errorMessage } from "@/lib/api";
import { cn } from "@/lib/utils";
import type { ConsoleIntegrationProps, ProgramActionProps, WebIntegration } from "../types";
import { captureToEvent, ID, useDisconnect, useEvents, useOutputs } from "./api";
import { ConnectDialog } from "./ConnectDialog";

const NAME = "AirBattleground";
const NO_MATCH = "__none";

/** This integration's part of the show link (null when the show is linked elsewhere or not at all). */
const ownLink = (link: ShowLink | null) => (link?.integration === ID ? link : null);

// ---------------------------------------------------------------- Settings → Connections

function ConnectPanel({ info }: { info: IntegrationInfo }) {
  const [open, setOpen] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const disconnect = useDisconnect();
  return (
    <div className="flex flex-wrap items-center gap-3">
      <div className="min-w-0 flex-1">
        <p className="font-semibold">{NAME}</p>
        {info.connected ? (
          <p className="text-sm text-muted-foreground">
            Connected{info.account ? ` as ${info.account.name}` : ""}
            {info.account?.org ? ` · ${info.account.org}` : ""}
            {info.host ? ` · ${info.host.replace(/^https?:\/\//, "")}` : ""}
          </p>
        ) : (
          <p className="text-sm text-muted-foreground">Link shows to your matches, go live on the Live page and send team lists and results.</p>
        )}
        {info.error && <p className="mt-1 text-sm text-destructive">{info.error}</p>}
      </div>
      {info.connected ? (
        <Button variant="outline" onClick={() => setConfirm(true)} disabled={disconnect.isPending}>
          <Unplug /> Disconnect
        </Button>
      ) : (
        <Button onClick={() => setOpen(true)}>
          <Plug /> Connect {NAME}
        </Button>
      )}
      <ConnectDialog open={open} onOpenChange={setOpen} />
      <ConfirmDialog
        open={confirm}
        onOpenChange={setConfirm}
        title={`Disconnect ${NAME}?`}
        description="This studio forgets the key. Shows stay, but they won't go to your matches or the Live page until you connect again."
        confirmLabel="Disconnect"
        destructive
        onConfirm={() =>
          disconnect.mutate(undefined, {
            onSuccess: () => toast.success(`${NAME} disconnected`),
            onError: (e) => toast.error("Couldn't disconnect", { description: errorMessage(e) }),
          })
        }
      />
    </div>
  );
}

// ---------------------------------------------------------------- console: match picker

function EventPicker({ info, link, setLink, live }: ConsoleIntegrationProps) {
  const events = useEvents(info.connected);
  const outputs = useOutputs(info.connected);
  const mine = ownLink(link);
  const items = events.data ?? [];
  const value = mine?.eventId ?? NO_MATCH;
  const pick = (v: string) => {
    if (v === NO_MATCH) {
      if (!mine) return;
      setLink(mine.outputIds.length ? { ...mine, eventId: null, eventTitle: null } : null);
      return;
    }
    const ev = items.find((e) => e.id === v);
    // first link to this integration: switch on the outputs it suggests
    const outputIds = mine ? mine.outputIds : (outputs.data ?? []).filter((o) => o.defaultOn).map((o) => o.id);
    setLink({ integration: ID, eventId: v, eventTitle: ev?.title ?? mine?.eventTitle ?? null, outputIds });
  };
  return (
    <Select value={value} onValueChange={pick} disabled={live || !info.connected}>
      <SelectTrigger className="h-9 w-60 text-xs" aria-label="Match">
        <SelectValue placeholder="Match" />
      </SelectTrigger>
      <SelectContent>
        <SelectItem value={NO_MATCH}>No match</SelectItem>
        {mine?.eventId && !items.some((e) => e.id === mine.eventId) && <SelectItem value={mine.eventId}>{mine.eventTitle ?? "Linked match"}</SelectItem>}
        {items.map((e) => (
          <SelectItem key={e.id} value={e.id}>
            <span className={cn("size-2 shrink-0 rounded-full", e.status === "live" ? "bg-destructive" : e.status === "upcoming" ? "bg-success" : "bg-muted-foreground/40")} />
            <span className="truncate">
              {e.title}
              {e.subtitle ? ` · ${e.subtitle}` : ""}
            </span>
          </SelectItem>
        ))}
        {events.isError && (
          <SelectItem value="__err" disabled>
            Couldn't load matches
          </SelectItem>
        )}
      </SelectContent>
    </Select>
  );
}

// ---------------------------------------------------------------- console: outputs

function OutputIcon({ o }: { o: IntegrationOutput }) {
  return o.kind === "youtube" ? <Youtube className="size-4 text-destructive" /> : null;
}

function OutputsGroup({ info, link, setLink, live }: ConsoleIntegrationProps) {
  const outputs = useOutputs(info.connected);
  const mine = ownLink(link);
  const otherLinked = !!link && link.integration !== ID;
  if (!info.connected) return null;
  const on = new Set(mine?.outputIds ?? []);
  const toggle = (id: string, v: boolean) => {
    const next = v ? [...on, id] : [...on].filter((x) => x !== id);
    if (!mine) {
      if (v) setLink({ integration: ID, eventId: null, eventTitle: null, outputIds: next });
      return;
    }
    setLink(next.length || mine.eventId ? { ...mine, outputIds: next } : null);
  };
  return (
    <div className="space-y-2 rounded-lg border bg-muted/30 p-2.5">
      <p className="text-xs font-bold tracking-wider text-muted-foreground uppercase">{NAME}</p>
      {outputs.isPending && <p className="text-xs text-muted-foreground">Loading…</p>}
      {outputs.isError && <p className="text-xs text-destructive">{errorMessage(outputs.error)}</p>}
      {otherLinked && <p className="text-xs text-muted-foreground">This show is linked to another connection.</p>}
      {(outputs.data ?? []).map((o) => (
        <label key={o.id} className={cn("flex items-center justify-between gap-2 text-sm", (live || otherLinked) && "opacity-60")}>
          <span className="flex min-w-0 items-center gap-1.5 truncate">
            <OutputIcon o={o} /> {o.name}
          </span>
          <Switch checked={on.has(o.id)} disabled={live || otherLinked} onCheckedChange={(v) => toggle(o.id, v)} />
        </label>
      ))}
    </div>
  );
}

// ---------------------------------------------------------------- console: captures

function ProgramActions({ link, snapshot }: ProgramActionProps) {
  const mine = ownLink(link);
  const [busy, setBusy] = useState<CaptureKind | null>(null);
  const [counts, setCounts] = useState<Record<CaptureKind, number>>({ SLOT_LIST: 0, RESULTS: 0 });
  useEffect(() => setCounts({ SLOT_LIST: 0, RESULTS: 0 }), [mine?.eventId]);
  if (!mine?.eventId) return null;
  const eventId = mine.eventId;
  const capture = async (kind: CaptureKind) => {
    setBusy(kind);
    try {
      const png = await snapshot();
      await captureToEvent(eventId, png, kind);
      setCounts((c) => ({ ...c, [kind]: c[kind] + 1 }));
      toast.success(kind === "SLOT_LIST" ? "Team list sent" : "Results sent", { description: `It's being read on ${NAME} now.` });
    } catch (e) {
      toast.error("Couldn't send the capture", { description: errorMessage(e) });
    } finally {
      setBusy(null);
    }
  };
  const btn = (kind: CaptureKind, icon: React.ReactNode, label: string) => (
    <Button variant="outline" size="sm" disabled={!!busy} onClick={() => void capture(kind)} title={`Put the ${label.toLowerCase()} on air, then tap to send it`}>
      {busy === kind ? <Loader2 className="animate-spin" /> : icon}
      {label}
      {counts[kind] > 0 && <span className="rounded-full bg-muted px-1.5 text-[10px] font-bold">{counts[kind]}</span>}
    </Button>
  );
  return (
    <div className="flex flex-wrap items-center gap-2">
      <span className="min-w-0 flex-1 truncate text-sm">
        <span className="font-semibold">{mine.eventTitle ?? "Match"}</span>
        <span className="text-muted-foreground"> · send what's on air</span>
      </span>
      {btn("SLOT_LIST", <ListOrdered />, "Team list")}
      {btn("RESULTS", <Trophy />, "Results")}
    </div>
  );
}

export const integration: WebIntegration = { id: ID, ConnectPanel, EventPicker, OutputsGroup, ProgramActions };
