import { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { formatDistanceToNow, parseISO } from "date-fns";
import { Clapperboard, MoreVertical, Plus, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { createShowSchema, type Show } from "@shared/types";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Skeleton } from "@/components/ui/skeleton";
import { Chip, EmptyState, PageHeader, QueryError } from "@/components/brand";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { ApiError, errorMessage } from "@/lib/api";
import { useCreateShow, useDeleteShow, useShows } from "@/lib/queries";

export default function ShowsPage() {
  const shows = useShows();
  const [creating, setCreating] = useState(false);
  const [deleting, setDeleting] = useState<Show | null>(null);
  const del = useDeleteShow();
  const list = [...(shows.data ?? [])].sort((a, b) => (a.state === "LIVE" ? -1 : b.state === "LIVE" ? 1 : b.updatedAt.localeCompare(a.updatedAt)));

  return (
    <>
      <PageHeader
        title="Shows"
        description="A show is your set of scenes for a stream or a recording. Open one to run it."
        actions={
          <Button size="lg" onClick={() => setCreating(true)}>
            <Plus /> New show
          </Button>
        }
      />
      {shows.isError ? (
        <QueryError title="Couldn't load your shows" message={errorMessage(shows.error)} onRetry={() => void shows.refetch()} />
      ) : shows.isPending ? (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {[0, 1, 2].map((i) => (
            <Skeleton key={i} className="h-32 rounded-xl" />
          ))}
        </div>
      ) : list.length === 0 ? (
        <EmptyState
          icon={<Clapperboard />}
          title="No shows yet"
          description="Create your first show. It comes with a few ready scenes: Starting soon, Phone, Host and Break."
          action={
            <Button size="lg" onClick={() => setCreating(true)}>
              <Plus /> Create a show
            </Button>
          }
        />
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {list.map((s) => (
            <div key={s.id} className="group relative flex animate-rise flex-col rounded-xl border bg-card p-4 transition-all hover:-translate-y-0.5 hover:shadow-glow">
              <div className="flex items-start gap-2">
                <div className="min-w-0 flex-1">
                  <h3 className="truncate font-display text-xl font-bold">{s.title}</h3>
                  <p className="text-xs text-muted-foreground">
                    {s.config.scenes.length} scenes · edited {formatDistanceToNow(parseISO(s.updatedAt), { addSuffix: true })}
                  </p>
                </div>
                {s.state === "LIVE" ? (
                  <Chip tone="live">● {s.outputs.destinationIds.length || s.link?.outputIds.length ? "LIVE" : "REC"}</Chip>
                ) : (
                  <DropdownMenu>
                    <DropdownMenuTrigger asChild>
                      <Button variant="ghost" size="icon-sm" aria-label={`More for ${s.title}`}>
                        <MoreVertical />
                      </Button>
                    </DropdownMenuTrigger>
                    <DropdownMenuContent align="end">
                      <DropdownMenuItem variant="destructive" onClick={() => setDeleting(s)}>
                        <Trash2 /> Delete show
                      </DropdownMenuItem>
                    </DropdownMenuContent>
                  </DropdownMenu>
                )}
              </div>
              <div className="mt-3 flex flex-wrap gap-1.5">
                {s.outputs.record && <Chip>Records on this PC</Chip>}
                {s.outputs.destinationIds.length > 0 && <Chip>{s.outputs.destinationIds.length} stream key{s.outputs.destinationIds.length > 1 ? "s" : ""}</Chip>}
                {s.link?.eventTitle && <Chip tone="primary">{s.link.eventTitle}</Chip>}
              </div>
              <Button asChild className="mt-4 w-full" variant={s.state === "LIVE" ? "destructive" : "default"}>
                <Link to={`/shows/${s.id}`}>{s.state === "LIVE" ? "Open (on air)" : "Open"}</Link>
              </Button>
            </div>
          ))}
        </div>
      )}
      <CreateShowDialog open={creating} onOpenChange={setCreating} />
      <ConfirmDialog
        open={!!deleting}
        onOpenChange={(o) => !o && setDeleting(null)}
        title={`Delete ${deleting?.title ?? "this show"}?`}
        description="Its scenes and settings are removed. Recordings you already made stay under Recordings."
        confirmLabel="Delete show"
        destructive
        onConfirm={() => deleting && del.mutate(deleting.id)}
      />
    </>
  );
}

function CreateShowDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (o: boolean) => void }) {
  const create = useCreateShow();
  const nav = useNavigate();
  const form = useForm<{ title: string }>({ resolver: zodResolver(createShowSchema), defaultValues: { title: "" } });
  const submit = form.handleSubmit((v) =>
    create.mutate(v.title, {
      onSuccess: (s) => {
        onOpenChange(false);
        form.reset({ title: "" });
        nav(`/shows/${s.id}`);
      },
      onError: (e) => {
        if (e instanceof ApiError && e.fields?.title) form.setError("title", { message: e.fields.title });
        else toast.error("Couldn't create the show", { description: errorMessage(e) });
      },
    }),
  );
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <form onSubmit={submit} className="space-y-4">
          <DialogHeader>
            <DialogTitle>New show</DialogTitle>
            <DialogDescription>Give it a name, like "Friday night finals". You can change it later.</DialogDescription>
          </DialogHeader>
          <div className="space-y-1.5">
            <Label htmlFor="show-title">Show name</Label>
            <Input id="show-title" autoFocus className="h-11 text-base" {...form.register("title")} aria-invalid={!!form.formState.errors.title} />
            {form.formState.errors.title && <p className="text-xs text-destructive">{form.formState.errors.title.message}</p>}
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              Cancel
            </Button>
            <Button type="submit" disabled={create.isPending}>
              {create.isPending ? "Creating…" : "Create and open"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
