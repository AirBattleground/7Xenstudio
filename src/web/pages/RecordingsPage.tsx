import { useState } from "react";
import { format, parseISO } from "date-fns";
import { Download, Film, HardDrive, Play, Trash2 } from "lucide-react";
import type { Recording } from "@shared/types";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Progress } from "@/components/ui/progress";
import { Skeleton } from "@/components/ui/skeleton";
import { Chip, EmptyState, PageHeader, QueryError } from "@/components/brand";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { errorMessage } from "@/lib/api";
import { formatBytes, formatDuration } from "@/lib/format";
import { useDeleteRecording, useRecordings } from "@/lib/queries";

const fileUrl = (r: Recording) => `/api/recordings/${encodeURIComponent(r.file)}`;

export default function RecordingsPage() {
  const recs = useRecordings();
  const del = useDeleteRecording();
  const [playing, setPlaying] = useState<Recording | null>(null);
  const [deleting, setDeleting] = useState<Recording | null>(null);
  const disk = recs.data?.disk;
  const usedPct = disk && disk.totalBytes ? Math.round(((disk.totalBytes - disk.freeBytes) / disk.totalBytes) * 100) : 0;

  return (
    <>
      <PageHeader title="Recordings" description="Every show recorded on this PC. Play, download or delete them here." />
      {disk && (
        <div className="mb-5 flex flex-wrap items-center gap-3 rounded-xl border bg-card p-4">
          <HardDrive className="size-5 text-primary" />
          <div className="min-w-48 flex-1">
            <p className="text-sm font-semibold">
              {formatBytes(disk.freeBytes)} free <span className="font-normal text-muted-foreground">of {formatBytes(disk.totalBytes)}</span>
            </p>
            <Progress value={usedPct} className="mt-1.5 h-2" />
          </div>
          {disk.freeBytes < 10 * 1024 ** 3 && <Chip tone="warning">Low on space: about {Math.floor(disk.freeBytes / (2.7 * 1024 ** 3))} h of recording left</Chip>}
        </div>
      )}
      {recs.isError ? (
        <QueryError title="Couldn't load the recordings" message={errorMessage(recs.error)} onRetry={() => void recs.refetch()} />
      ) : recs.isPending ? (
        <div className="space-y-2">
          {[0, 1, 2].map((i) => (
            <Skeleton key={i} className="h-20 rounded-xl" />
          ))}
        </div>
      ) : recs.data.items.length === 0 ? (
        <EmptyState icon={<Film />} title="No recordings yet" description='Open a show, turn on "Record on this PC" in Outputs, and press Start recording or Go live.' />
      ) : (
        <ul className="space-y-2">
          {recs.data.items.map((r) => {
            const secs = (Date.parse(r.updatedAt) - Date.parse(r.startedAt)) / 1000;
            return (
              <li key={r.file} className="flex animate-rise flex-wrap items-center gap-3 rounded-xl border bg-card p-3 sm:p-4">
                <div className="flex size-11 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary">
                  <Film className="size-5" />
                </div>
                <div className="min-w-0 flex-1">
                  <p className="truncate font-display text-lg font-bold">{r.title}</p>
                  <p className="truncate text-xs text-muted-foreground">
                    {format(parseISO(r.startedAt), "EEE, d MMM yyyy · h:mm a")} · {formatDuration(secs)} · {formatBytes(r.sizeBytes)}
                  </p>
                </div>
                {r.recording && <Chip tone="live">● Recording now</Chip>}
                <div className="flex items-center gap-1">
                  <Button variant="outline" size="sm" onClick={() => setPlaying(r)}>
                    <Play /> Play
                  </Button>
                  <Button asChild variant="outline" size="sm">
                    <a href={`${fileUrl(r)}?download=1`} download={r.file}>
                      <Download /> <span className="hidden sm:inline">Download</span>
                    </a>
                  </Button>
                  <Button variant="ghost" size="icon-sm" className="text-muted-foreground hover:text-destructive" aria-label={`Delete ${r.title}`} disabled={r.recording} onClick={() => setDeleting(r)}>
                    <Trash2 />
                  </Button>
                </div>
              </li>
            );
          })}
        </ul>
      )}
      <Dialog open={!!playing} onOpenChange={(o) => !o && setPlaying(null)}>
        <DialogContent className="sm:max-w-4xl">
          <DialogHeader>
            <DialogTitle>{playing?.title}</DialogTitle>
            <DialogDescription>{playing?.file}</DialogDescription>
          </DialogHeader>
          {playing && <video src={fileUrl(playing)} controls autoPlay playsInline className="aspect-video w-full rounded-lg bg-black" />}
        </DialogContent>
      </Dialog>
      <ConfirmDialog
        open={!!deleting}
        onOpenChange={(o) => !o && setDeleting(null)}
        title="Delete this recording?"
        description={`${deleting?.title ?? ""} (${deleting ? formatBytes(deleting.sizeBytes) : ""}) is removed from this PC for good.`}
        confirmLabel="Delete recording"
        destructive
        onConfirm={() => deleting && del.mutate(deleting.file)}
      />
    </>
  );
}
