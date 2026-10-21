import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { QRCodeSVG } from "qrcode.react";
import { Check, Copy, Smartphone } from "lucide-react";
import { toast } from "sonner";
import { deviceNameSchema, type CreatedDevice } from "@shared/types";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { ApiError, errorMessage } from "@/lib/api";
import { useCreateDevice } from "@/lib/queries";

type Form = { name: string };

/** Add a phone: name it, then scan the QR with the 7XEN Stream app (the key is shown once). */
export function AddPhoneDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (o: boolean) => void }) {
  const create = useCreateDevice();
  const [created, setCreated] = useState<CreatedDevice | null>(null);
  const [copied, setCopied] = useState(false);
  const form = useForm<Form>({ resolver: zodResolver(deviceNameSchema), defaultValues: { name: "" } });

  useEffect(() => {
    if (open) {
      setCreated(null);
      setCopied(false);
      form.reset({ name: "" });
    }
  }, [open, form]);

  const submit = form.handleSubmit((v) =>
    create.mutate(v.name, {
      onSuccess: (d) => setCreated(d),
      onError: (e) => {
        if (e instanceof ApiError && e.fields?.name) form.setError("name", { message: e.fields.name });
        else toast.error("Couldn't add the phone", { description: errorMessage(e) });
      },
    }),
  );

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        {!created ? (
          <form onSubmit={submit} className="space-y-4">
            <DialogHeader>
              <DialogTitle>Add a phone</DialogTitle>
              <DialogDescription>Give it a name you'll recognise, like "Player cam 1" or "Desk phone".</DialogDescription>
            </DialogHeader>
            <div className="space-y-1.5">
              <Label htmlFor="phone-name">Phone name</Label>
              <Input id="phone-name" autoFocus placeholder="Player cam 1" {...form.register("name")} aria-invalid={!!form.formState.errors.name} className="h-11 text-base" />
              {form.formState.errors.name && <p className="text-xs text-destructive">{form.formState.errors.name.message}</p>}
            </div>
            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
                Cancel
              </Button>
              <Button type="submit" disabled={create.isPending}>
                <Smartphone /> {create.isPending ? "Adding…" : "Add phone"}
              </Button>
            </DialogFooter>
          </form>
        ) : (
          <div className="space-y-4">
            <DialogHeader>
              <DialogTitle>Connect {created.device.name}</DialogTitle>
              <DialogDescription>The phone must be on the same Wi-Fi as this PC.</DialogDescription>
            </DialogHeader>
            <div className="flex justify-center">
              {/* dark-on-white so every phone camera reads it, in light and dark theme */}
              <div className="rounded-xl bg-[#ffffff] p-4 shadow-sm">
                <QRCodeSVG value={created.pairUrl} size={220} bgColor="#ffffff" fgColor="#000000" level="M" />
              </div>
            </div>
            <ol className="grid gap-2 text-sm">
              {["Open 7XEN Stream on the phone", "Tap Scan QR and point it at this code", "Tap Start streaming"].map((s, i) => (
                <li key={s} className="flex items-center gap-3">
                  <span className="flex size-7 shrink-0 items-center justify-center rounded-full bg-primary/15 font-display font-bold text-primary">{i + 1}</span>
                  {s}
                </li>
              ))}
            </ol>
            <div className="rounded-lg border bg-muted/50 p-3">
              <p className="text-xs text-muted-foreground">Can't scan? Type this key in the app. It's shown only once.</p>
              <div className="mt-1.5 flex items-center gap-2">
                <code className="min-w-0 flex-1 truncate font-mono text-sm font-semibold">{created.key}</code>
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() =>
                    void navigator.clipboard
                      ?.writeText(created.key)
                      .then(() => setCopied(true))
                      .catch(() => toast.error("Couldn't copy — select the key and copy it"))
                  }
                >
                  {copied ? <Check /> : <Copy />} {copied ? "Copied" : "Copy"}
                </Button>
              </div>
            </div>
            <DialogFooter>
              <Button onClick={() => onOpenChange(false)}>Done</Button>
            </DialogFooter>
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}
