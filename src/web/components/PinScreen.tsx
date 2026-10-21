import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { Lock } from "lucide-react";
import { pinSchema } from "@shared/types";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { ApiError, api, errorMessage } from "@/lib/api";
import { Logo } from "./brand";

/** Shown when this studio has a PIN and this browser hasn't entered it yet. */
export function PinScreen({ studioName, onUnlocked }: { studioName?: string; onUnlocked: () => void }) {
  const form = useForm<{ pin: string }>({ resolver: zodResolver(pinSchema), defaultValues: { pin: "" } });
  const submit = form.handleSubmit(async (v) => {
    try {
      await api.post("/api/session", v);
      onUnlocked();
    } catch (e) {
      form.setError("pin", { message: e instanceof ApiError && e.status === 401 ? "That PIN isn't right. Try again." : errorMessage(e) });
    }
  });
  return (
    <div className="flex min-h-dvh items-center justify-center bg-background bg-grid p-4">
      <form onSubmit={submit} className="w-full max-w-sm animate-rise space-y-5 rounded-2xl border bg-card p-6 shadow-glow">
        <Logo />
        <div>
          <h1 className="flex items-center gap-2 font-display text-2xl font-bold">
            <Lock className="size-5 text-primary" /> Enter the studio PIN
          </h1>
          <p className="mt-1 text-sm text-muted-foreground">{studioName ? `${studioName} is protected.` : "This studio is protected."} Ask the person who set it up for the PIN.</p>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="pin">PIN</Label>
          <Input id="pin" type="password" inputMode="numeric" autoComplete="current-password" autoFocus className="h-12 text-center font-display text-2xl tracking-[0.4em]" {...form.register("pin")} aria-invalid={!!form.formState.errors.pin} />
          {form.formState.errors.pin && <p className="text-sm text-destructive">{form.formState.errors.pin.message}</p>}
        </div>
        <Button type="submit" size="lg" className="h-12 w-full text-base" disabled={form.formState.isSubmitting}>
          {form.formState.isSubmitting ? "Checking…" : "Unlock"}
        </Button>
      </form>
    </div>
  );
}
