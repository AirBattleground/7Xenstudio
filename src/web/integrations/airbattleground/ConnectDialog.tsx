import { useEffect, useRef, useState } from "react";
import { Camera, Link2, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { errorMessage } from "@/lib/api";
import { useConnect } from "./api";
import { parseConnectLink } from "./link";

/** Chrome's BarcodeDetector (not in TypeScript's DOM types yet). */
interface DetectedBarcode {
  rawValue: string;
}
interface BarcodeDetectorLike {
  detect(source: CanvasImageSource): Promise<DetectedBarcode[]>;
}
type BarcodeDetectorCtor = new (opts: { formats: string[] }) => BarcodeDetectorLike;
const Detector = (globalThis as unknown as { BarcodeDetector?: BarcodeDetectorCtor }).BarcodeDetector;

/**
 * "Connect AirBattleground": scan the QR from AirBattleground → Manager → Studio → "Connect a studio" with this PC's
 * webcam, or paste the link / key.
 */
export function ConnectDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (o: boolean) => void }) {
  const connect = useConnect();
  const [text, setText] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [scanning, setScanning] = useState(false);
  const [camError, setCamError] = useState<string | null>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  const busy = useRef(false);

  useEffect(() => {
    if (!open) return;
    setText("");
    setError(null);
    setCamError(null);
    setScanning(!!Detector);
  }, [open]);

  const submit = (raw: string) => {
    if (busy.current) return;
    if (!parseConnectLink(raw)) {
      setError("That isn't a studio link. Copy the whole link (7xen-studio://connect…) or the key starting with sw_.");
      return;
    }
    busy.current = true;
    setError(null);
    connect.mutate(raw.trim(), {
      onSuccess: (info) => {
        toast.success("AirBattleground connected", { description: info.account ? `Signed in as ${info.account.name}` : undefined });
        onOpenChange(false);
      },
      onError: (e) => setError(errorMessage(e)),
      onSettled: () => {
        busy.current = false;
      },
    });
  };
  const submitRef = useRef(submit);
  submitRef.current = submit;

  // webcam + BarcodeDetector loop
  useEffect(() => {
    if (!open || !scanning || !Detector) return;
    let stream: MediaStream | null = null;
    let timer: number | null = null;
    let alive = true;
    const detector = new Detector({ formats: ["qr_code"] });
    void (async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" }, audio: false });
        if (!alive) return stream.getTracks().forEach((t) => t.stop());
        const v = videoRef.current;
        if (!v) return;
        v.srcObject = stream;
        await v.play().catch(() => undefined);
        const tick = async () => {
          if (!alive) return;
          if (v.readyState >= 2 && !busy.current) {
            const codes = await detector.detect(v).catch(() => [] as DetectedBarcode[]);
            const hit = codes.find((c) => parseConnectLink(c.rawValue));
            if (hit) {
              setText(hit.rawValue);
              submitRef.current(hit.rawValue);
            }
          }
          timer = window.setTimeout(() => void tick(), 300);
        };
        void tick();
      } catch {
        if (alive) {
          setCamError("Couldn't open the webcam. Allow camera access, or paste the link below.");
          setScanning(false);
        }
      }
    })();
    return () => {
      alive = false;
      if (timer !== null) window.clearTimeout(timer);
      stream?.getTracks().forEach((t) => t.stop());
    };
  }, [open, scanning]);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Connect AirBattleground</DialogTitle>
          <DialogDescription>On AirBattleground open Manager → Studio → "Connect a studio", then show the QR code to this PC's webcam.</DialogDescription>
        </DialogHeader>
        {scanning ? (
          <div className="relative overflow-hidden rounded-lg border bg-muted">
            <video ref={videoRef} muted playsInline className="block aspect-video w-full object-cover" />
            <div className="pointer-events-none absolute inset-8 rounded-lg border-2 border-primary/70" />
            <p className="absolute right-0 bottom-0 left-0 bg-background/80 px-3 py-1.5 text-center text-xs font-medium">
              {connect.isPending ? "Connecting…" : "Looking for the QR code…"}
            </p>
          </div>
        ) : (
          Detector && (
            <Button variant="outline" onClick={() => (setCamError(null), setScanning(true))}>
              <Camera /> Scan with the webcam
            </Button>
          )
        )}
        {!Detector && <p className="rounded-lg bg-muted p-3 text-sm text-muted-foreground">This browser can't scan QR codes. Copy the link on AirBattleground and paste it below.</p>}
        {camError && <p className="text-sm text-warning-foreground dark:text-warning">{camError}</p>}
        <form
          className="space-y-2"
          onSubmit={(e) => {
            e.preventDefault();
            submit(text);
          }}
        >
          <Label htmlFor="abg-link">Or paste the link or key</Label>
          <Input id="abg-link" value={text} onChange={(e) => setText(e.target.value)} placeholder="7xen-studio://connect?… or sw_…" autoComplete="off" aria-invalid={!!error} />
          {error && <p className="text-sm text-destructive">{error}</p>}
          <DialogFooter className="pt-2">
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              Cancel
            </Button>
            <Button type="submit" disabled={connect.isPending || !text.trim()}>
              {connect.isPending ? <Loader2 className="animate-spin" /> : <Link2 />} Connect
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
