/**
 * The show console (`/shows/:id`): Program + Preview monitors, scenes with TAKE (cut/fade, keys 1–9), sources,
 * overlays and outputs. This browser runs its own StudioMixer for the monitors; every take is mirrored to the server
 * (PATCH /control), whose renderer on the studio PC draws the same scenes and makes the real output.
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { ArrowLeft, Circle, Clapperboard, Layers, Loader2, MonitorPlay, Plus, Radio, Square } from "lucide-react";
import { toast } from "sonner";
import type { Destination, DeviceRow, Prop, Scene, Show, ShowConfig, ShowLink, ShowOutputs } from "@shared/types";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { QueryError } from "@/components/brand";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { HlsVideo } from "@/components/HlsVideo";
import { LiveHealth } from "@/components/console/LiveHealth";
import { MonitorLabel, PreviewMonitor, ProgramMonitor } from "@/components/console/Monitors";
import { OutputsPanel, OverlaysPanel, SourcesPanel, TransitionToggle } from "@/components/console/Panels";
import { SceneCard, SceneEditor } from "@/components/console/Scenes";
import { fadeMsOf, goLiveMode, normalizeConfig, resolveScene, sceneForKey, sid } from "@/engine/config";
import { StudioMixer } from "@/engine/mixer";
import { integrationUi, type ConsoleIntegrationProps, type WebIntegration } from "@/integrations/registry";
import { errorMessage } from "@/lib/api";
import { fetchControl, useDestinations, useDevices, useInfo, useIntegrations, useProps, useShow, useShowStatus, useStartShow, useStopShow, useUpdateControl, useUpdateShow } from "@/lib/queries";
import { cn } from "@/lib/utils";

export default function ConsolePage() {
  const { showId } = useParams();
  const q = useShow(showId);
  const devices = useDevices();
  const props = useProps();
  const dests = useDestinations();
  const wrap = (node: React.ReactNode) => <div className="mx-auto max-w-3xl p-6">{node}</div>;
  if (q.isError) return wrap(<QueryError title="Couldn't load this show" message={errorMessage(q.error)} onRetry={() => void q.refetch()} />);
  if (devices.isError && !devices.data) return wrap(<QueryError title="Couldn't load your phones" message={errorMessage(devices.error)} onRetry={() => void devices.refetch()} />);
  if (!q.data || !devices.data || !props.data || !dests.data)
    return (
      <div className="grid gap-4 p-4 xl:grid-cols-[18rem_minmax(0,1fr)_18rem]">
        <Skeleton className="h-96 rounded-xl" />
        <Skeleton className="aspect-video w-full rounded-xl" />
        <Skeleton className="h-96 rounded-xl" />
      </div>
    );
  return <WithMixer key={q.data.id} show={q.data} />;
}

/** One mixer per mount (created in the effect so React's StrictMode double-mount gets a fresh, working one). */
function WithMixer({ show }: { show: Show }) {
  const [mixer, setMixer] = useState<StudioMixer | null>(null);
  useEffect(() => {
    const m = new StudioMixer({ fps: show.fps });
    setMixer(m);
    return () => m.dispose();
  }, [show.fps]);
  if (!mixer) return <Skeleton className="m-4 aspect-video rounded-xl" />;
  return <Console key={mixer.id} show={show} mixer={mixer} />;
}

function Console({ show, mixer }: { show: Show; mixer: StudioMixer }) {
  const devices: DeviceRow[] = useDevices().data ?? [];
  const props: Prop[] = useProps().data ?? [];
  const destinations: Destination[] = useDestinations().data ?? [];
  const info = useInfo();
  const update = useUpdateShow(show.id);
  const updateControl = useUpdateControl(show.id);
  const start = useStartShow(show.id);
  const stop = useStopShow(show.id);

  const [config, setConfig] = useState<ShowConfig>(() => normalizeConfig(show.config));
  const [title, setTitle] = useState(show.title);
  const [outputs, setOutputsState] = useState<ShowOutputs>(show.outputs);
  const [link, setLinkState] = useState<ShowLink | null>(show.link ?? null);
  const [previewId, setPreviewId] = useState<string | null>(config.scenes[1]?.id ?? config.scenes[0]?.id ?? null);
  const [programId, setProgramId] = useState<string | null>(null);
  const [editing, setEditing] = useState<Scene | null>(null);
  const [confirm, setConfirm] = useState<"start" | "end" | null>(null);
  const [watchOut, setWatchOut] = useState(false);

  // polled every 2 s while live
  const status = useShowStatus(show.id, start.isPending);
  const st = status.data ?? null;
  const live = st ? st.state === "LIVE" : show.state === "LIVE";

  // studio name on the slate, LIVE bug clock while the show is live
  useEffect(() => {
    if (info.data?.name) mixer.slateTitle = info.data.name;
  }, [info.data?.name, mixer]);
  useEffect(() => {
    mixer.setLiveClock(live ? (st?.liveSince ? Date.parse(st.liveSince) : Date.now()) : null);
  }, [mixer, live, st?.liveSince]);
  useEffect(() => {
    mixer.overlays = config.overlays;
  }, [config.overlays, mixer]);

  // autosave the config (debounced 300 ms)
  const first = useRef(true);
  const mutateShow = update.mutate;
  useEffect(() => {
    if (first.current) {
      first.current = false;
      return;
    }
    const t = window.setTimeout(() => mutateShow({ config }), 300);
    return () => window.clearTimeout(t);
  }, [config, mutateShow]);

  const setOutputs = (o: ShowOutputs) => {
    setOutputsState(o);
    mutateShow({ outputs: o });
  };
  const setLink = useCallback(
    (l: ShowLink | null) => {
      setLinkState(l);
      mutateShow({ link: l });
    },
    [mutateShow],
  );

  const scenes = config.scenes;
  const preview = scenes.find((s) => s.id === previewId) ?? null;
  const program = scenes.find((s) => s.id === programId) ?? null;
  const resolve = useCallback((s: Scene): Scene => resolveScene(s, config.introPropId), [config.introPropId]);

  // takes: mirrored to the renderer with an increasing sequence number
  const takeSeq = useRef(0);
  const liveRef = useRef(live);
  liveRef.current = live;
  const mutateControl = updateControl.mutate;
  const sendTake = useCallback(
    (id: string) =>
      mutateControl(
        { programId: id, takeSeq: ++takeSeq.current },
        { onError: (e) => liveRef.current && toast.error("The studio PC didn't get that scene change", { description: errorMessage(e) }) },
      ),
    [mutateControl],
  );
  const take = useCallback(
    async (scene: Scene | null, opts?: { local?: boolean }) => {
      if (!scene) return;
      if (!opts?.local) sendTake(scene.id);
      setProgramId(scene.id);
      await mixer.take(resolve(scene), fadeMsOf(config));
    },
    [config, mixer, resolve, sendTake],
  );

  // on open: pick up the control state (what's on air if the show is live), else start on the first scene
  useEffect(() => {
    let alive = true;
    void fetchControl(show.id)
      .then((c) => {
        if (!alive) return;
        takeSeq.current = Math.max(takeSeq.current, c.takeSeq);
        const onAir = scenes.find((s) => s.id === c.programId);
        void take(onAir ?? scenes[0] ?? null, { local: true });
      })
      .catch(() => alive && void take(scenes[0] ?? null, { local: true }));
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // an edited on-air scene re-takes at once (the renderer picks the config change up by itself)
  const onAirJson = program ? JSON.stringify(resolve(program)) : "";
  const lastOnAir = useRef(onAirJson);
  useEffect(() => {
    if (program && lastOnAir.current && onAirJson !== lastOnAir.current) void mixer.take(resolve(program), 0);
    lastOnAir.current = onAirJson;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [onAirJson]);

  // keyboard: 1–9 takes scene n
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement | null;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
      if (e.ctrlKey || e.metaKey || e.altKey || document.querySelector("[role=dialog]")) return;
      const s = sceneForKey(scenes, e.key);
      if (s) {
        setPreviewId(s.id);
        void take(s);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [scenes, take]);

  // integrations (from the registry) that are connected on the server
  const integrations = useIntegrations();
  const active = useMemo(
    () => (integrations.data ?? []).filter((i) => i.connected).flatMap((i) => (integrationUi(i.id) ? [{ info: i, ui: integrationUi(i.id) as WebIntegration }] : [])),
    [integrations.data],
  );
  const ctxFor = (i: (typeof active)[number]): ConsoleIntegrationProps => ({ info: i.info, show, link, setLink, live });

  const mode = goLiveMode(outputs, link?.outputIds ?? []);
  const recordOnly = mode === "record";

  const goLive = async () => {
    setConfirm(null);
    try {
      // make sure the renderer starts on what's on air here
      if (programId) await updateControl.mutateAsync({ programId, takeSeq: ++takeSeq.current });
    } catch {
      /* the start still works; the renderer shows the last scene it knows */
    }
    start.mutate(undefined, {
      onSuccess: () => {
        toast.success(recordOnly ? "Recording started" : "You're live");
        void status.refetch();
      },
    });
  };
  const endShow = () => {
    setConfirm(null);
    stop.mutate(undefined, {
      onSuccess: () => {
        toast.success(recordOnly ? "Recording saved" : "Show ended", { description: outputs.record ? "Find it under Recordings." : undefined });
        void status.refetch();
      },
    });
  };

  const saveTitle = () => {
    const t = title.trim();
    if (t.length >= 2 && t !== show.title) mutateShow({ title: t });
    else if (t.length < 2) setTitle(show.title);
  };

  const busy = start.isPending || stop.isPending;

  return (
    <div className="flex min-h-[calc(100dvh-3.5rem)] flex-col">
      {/* top bar */}
      <div className="flex flex-wrap items-center gap-2 border-b bg-card/70 px-4 py-2.5 backdrop-blur sm:gap-3">
        <Button asChild variant="ghost" size="icon-sm" aria-label="Back to shows">
          <Link to="/">
            <ArrowLeft />
          </Link>
        </Button>
        <Clapperboard className="hidden size-5 text-primary sm:block" />
        <Input value={title} maxLength={80} onChange={(e) => setTitle(e.target.value)} onBlur={saveTitle} onKeyDown={(e) => e.key === "Enter" && e.currentTarget.blur()} className="h-9 w-48 font-display text-lg font-bold sm:w-56" aria-label="Show name" />
        {active.map((i) => i.ui.EventPicker && <i.ui.EventPicker key={i.info.id} {...ctxFor(i)} />)}
        <TransitionToggle value={config.transition} onChange={(v) => setConfig((c) => ({ ...c, transition: v }))} />
        <div className="ml-auto flex flex-wrap items-center gap-2">
          <LiveHealth status={st} fps={show.fps} />
          {live && (
            <Button variant="outline" size="sm" onClick={() => setWatchOut(true)} title="The real output from the studio PC (a few seconds behind)">
              <MonitorPlay /> Watch output
            </Button>
          )}
          {live ? (
            <Button variant="destructive" size="lg" data-tour="studio-golive" disabled={busy} onClick={() => setConfirm("end")}>
              {stop.isPending ? <Loader2 className="animate-spin" /> : <Square className="fill-current" />} End show
            </Button>
          ) : mode === "none" ? (
            <Tooltip>
              <TooltipTrigger asChild>
                <span tabIndex={0}>
                  <Button size="lg" disabled>
                    <Radio /> Go live
                  </Button>
                </span>
              </TooltipTrigger>
              <TooltipContent>Turn on "Record on this PC" or a stream key in Outputs first</TooltipContent>
            </Tooltip>
          ) : (
            <Button size="lg" data-tour="studio-golive" className="shadow-glow" disabled={busy} onClick={() => setConfirm("start")}>
              {start.isPending ? <Loader2 className="animate-spin" /> : recordOnly ? <Circle className="fill-current text-destructive" /> : <Radio />} {recordOnly ? "Start recording" : "Go live"}
            </Button>
          )}
        </div>
      </div>

      <div className="grid flex-1 gap-4 p-4 xl:grid-cols-[17rem_minmax(0,1fr)_18rem]">
        <div className="order-2 xl:order-1">
          <SourcesPanel mixer={mixer} devices={devices} props={props} config={config} setConfig={setConfig} />
        </div>

        {/* monitors + scenes */}
        <div className="order-1 flex min-w-0 flex-col gap-4 xl:order-2">
          <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_16rem]">
            <div data-tour="studio-program" className="min-w-0">
              <MonitorLabel tone={live ? "live" : "program"} text={live ? "On air" : "Program"} sub={program?.name} />
              <ProgramMonitor mixer={mixer} live={live} />
              {active.map(
                (i) =>
                  i.ui.ProgramActions && (
                    <div key={i.info.id} className="mt-2 rounded-lg border bg-card px-3 py-2">
                      <i.ui.ProgramActions {...ctxFor(i)} snapshot={() => mixer.snapshot()} />
                    </div>
                  ),
              )}
            </div>
            <div className="flex flex-col gap-3">
              <div>
                <MonitorLabel tone="preview" text="Preview" sub={preview?.name} />
                <PreviewMonitor mixer={mixer} scene={preview ? resolve(preview) : null} />
              </div>
              <Button size="lg" className="h-16 text-xl font-bold tracking-wider" disabled={!preview || preview.id === programId} onClick={() => void take(preview)}>
                TAKE · {config.transition === "fade" ? "FADE" : "CUT"}
              </Button>
              <p className="text-xs text-muted-foreground">Click a scene to preview it, then TAKE. Or double-click it, or press 1–9, to put it straight on air.</p>
            </div>
          </div>

          <section data-tour="studio-scenes" className="rounded-xl border bg-card p-3">
            <div className="mb-2 flex items-center justify-between">
              <h2 className="flex items-center gap-2 font-display text-lg font-bold">
                <Layers className="size-4 text-primary" /> Scenes
              </h2>
              <Button
                size="sm"
                variant="outline"
                disabled={scenes.length >= 30}
                onClick={() => {
                  const s: Scene = { id: sid(), name: `Scene ${scenes.length + 1}`, layout: "full", slots: [null] };
                  setConfig((c) => ({ ...c, scenes: [...c.scenes, s] }));
                  setEditing(s);
                }}
              >
                <Plus /> Add scene
              </Button>
            </div>
            {scenes.length === 0 ? (
              <p className="py-6 text-center text-sm text-muted-foreground">No scenes yet. Tap Add scene to make your first one.</p>
            ) : (
              <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-4 2xl:grid-cols-6">
                {scenes.map((s, i) => (
                  <SceneCard
                    key={s.id}
                    scene={s}
                    index={i}
                    devices={devices}
                    props={props}
                    onAir={s.id === programId}
                    selected={s.id === previewId}
                    onSelect={() => setPreviewId(s.id)}
                    onTake={() => (setPreviewId(s.id), void take(s))}
                    onEdit={() => setEditing(s)}
                  />
                ))}
              </div>
            )}
          </section>
        </div>

        <aside className="order-3 flex flex-col gap-3">
          <OutputsPanel
            outputs={outputs}
            setOutputs={setOutputs}
            destinations={destinations}
            live={live}
            extra={active.map((i) => i.ui.OutputsGroup && <i.ui.OutputsGroup key={i.info.id} {...ctxFor(i)} />)}
          />
          <OverlaysPanel config={config} setConfig={setConfig} props={props} />
        </aside>
      </div>

      <SceneEditor
        scene={editing}
        devices={devices}
        props={props}
        canDelete={scenes.length > 1 && editing?.id !== programId}
        onClose={() => setEditing(null)}
        onSave={(s) => {
          setConfig((c) => ({ ...c, scenes: c.scenes.map((x) => (x.id === s.id ? s : x)) }));
          setEditing(null);
        }}
        onDelete={(s) => {
          setConfig((c) => ({ ...c, scenes: c.scenes.filter((x) => x.id !== s.id) }));
          if (previewId === s.id) setPreviewId(null);
          setEditing(null);
        }}
      />
      <ConfirmDialog
        open={confirm === "start"}
        onOpenChange={(o) => !o && setConfirm(null)}
        title={recordOnly ? "Start recording?" : "Go live?"}
        description={
          recordOnly
            ? "The studio PC records the show. Nothing is sent anywhere."
            : `The show goes out to ${[outputs.record ? "the recording on this PC" : null, ...outputs.destinationIds.map((id) => destinations.find((d) => d.id === id)?.name ?? "a stream key"), link?.outputIds.length ? `${link.outputIds.length} connected output${link.outputIds.length > 1 ? "s" : ""}` : null].filter(Boolean).join(", ")}. Start on your intro scene.`
        }
        confirmLabel={recordOnly ? "Start recording" : "Go live"}
        onConfirm={() => void goLive()}
      />
      <ConfirmDialog
        open={confirm === "end"}
        onOpenChange={(o) => !o && setConfirm(null)}
        title={recordOnly ? "Stop recording?" : "End the show?"}
        description={recordOnly ? "The recording is saved on this PC — find it under Recordings." : "The stream stops for everyone watching. You can go live again any time."}
        confirmLabel={recordOnly ? "Stop recording" : "End show"}
        destructive
        onConfirm={endShow}
      />
      <Dialog open={watchOut} onOpenChange={setWatchOut}>
        <DialogContent className="sm:max-w-4xl">
          <DialogHeader>
            <DialogTitle>Real output</DialogTitle>
            <DialogDescription>What the studio PC is sending, a few seconds behind.</DialogDescription>
          </DialogHeader>
          {watchOut && <HlsVideo src={`/api/shows/${show.id}/live/index.m3u8`} className={cn("aspect-video w-full")} />}
        </DialogContent>
      </Dialog>
    </div>
  );
}
