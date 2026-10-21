/**
 * The render page (`/render/:showId?t=<render token>`), opened by the server's renderer in headless Chrome on this
 * PC. No chrome: it draws the show with a StudioMixer driven by the control state (long-poll), and records it.
 *
 * - Auth: the `t` token is sent on every API fetch and hls.js request as the RENDER_TOKEN_HEADER header, and added
 *   as `?t=` to <video>/<img> media URLs (they can't send headers).
 * - It waits for the first take, then (when the renderer exposed `window.__swChunk`) records at RENDER_VIDEO_BPS in
 *   500 ms chunks and hands them over in order, awaiting each one. `window.__swStatus` gets fps/recording/error
 *   every second.
 * - The webcam doesn't exist here: camera slots show the slate.
 */
import { useEffect, useRef, useState } from "react";
import { useParams, useSearchParams } from "react-router-dom";
import { RENDER_VIDEO_BPS, STUDIO_HEIGHT, STUDIO_WIDTH, type ControlState, type RenderStatus, type Scene, type Show, type StudioInfo } from "@shared/types";
import { fadeMsOf, normalizeConfig, resolveSceneForRender } from "@/engine/config";
import { StudioMixer } from "@/engine/mixer";
import { api, errorMessage, setApiHeader } from "@/lib/api";
import { blobToBase64 } from "@/lib/base64";
import { RENDER_TOKEN_HEADER, withToken } from "@/lib/render-token";
import { fetchControl } from "@/lib/queries";

declare global {
  interface Window {
    __swChunk?: (base64: string) => unknown;
    __swStatus?: (s: RenderStatus) => unknown;
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export default function RenderPage() {
  const { showId = "" } = useParams();
  const [search] = useSearchParams();
  const token = search.get("t");
  const host = useRef<HTMLDivElement>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    document.title = "7XEN Studio · render";
    setApiHeader(RENDER_TOKEN_HEADER, token);
    let alive = true;
    const abort = new AbortController();
    let mixer: StudioMixer | null = null;
    let statusTimer: number | null = null;

    const report = (err: string | null) => {
      if (!mixer) return;
      try {
        void window.__swStatus?.({ fps: mixer.status.fps, recording: mixer.capture.recording, error: err ?? mixer.capture.error });
      } catch {
        /* the renderer went away */
      }
    };

    void (async () => {
      // the show (for its frame rate); retry until the server answers
      let show: Show | null = null;
      while (alive && !show) {
        try {
          show = await api.get<Show>(`/api/shows/${showId}`, { signal: abort.signal });
        } catch (e) {
          if (!alive) return;
          setError(errorMessage(e));
          await sleep(1000);
        }
      }
      if (!alive || !show) return;
      setError(null);
      const m = new StudioMixer({ fps: show.fps });
      mixer = m;
      m.mediaUrl = (p) => withToken(p, token);
      if (token) m.hlsHeaders = { [RENDER_TOKEN_HEADER]: token };
      m.canvas.style.cssText = "display:block;width:100%;height:100%;object-fit:contain";
      host.current?.appendChild(m.canvas);
      void api
        .get<StudioInfo>("/api/info", { signal: abort.signal })
        .then((info) => (m.slateTitle = info.name))
        .catch(() => undefined);
      statusTimer = window.setInterval(() => report(null), 1000);

      let since = -1;
      let lastTake = -1;
      let onAirKey = "";
      let firstTake = false;
      while (alive) {
        let st: ControlState;
        try {
          st = await fetchControl(showId, since, abort.signal);
        } catch (e) {
          if (!alive) return;
          report(errorMessage(e));
          await sleep(1000);
          continue;
        }
        since = st.version;
        const config = normalizeConfig(st.config);
        m.overlays = config.overlays;
        m.setLiveClock(st.state === "LIVE" ? (st.liveSince ? Date.parse(st.liveSince) : Date.now()) : null);
        const scene: Scene | undefined = st.programId ? config.scenes.find((s) => s.id === st.programId) : undefined;
        if (scene) {
          const resolved = resolveSceneForRender(scene, config.introPropId);
          const key = JSON.stringify(resolved);
          if (st.takeSeq !== lastTake) {
            // a new take (or the first one): cut/fade like the console did
            await m.take(resolved, firstTake ? fadeMsOf(config) : 0);
            lastTake = st.takeSeq;
            onAirKey = key;
            firstTake = true;
          } else if (key !== onAirKey) {
            // the on-air scene was edited: show the change at once
            await m.take(resolved, 0);
            onAirKey = key;
          }
        }
        if (firstTake && !m.capturing && typeof window.__swChunk === "function") {
          const send = window.__swChunk;
          m.startCapture({
            bitsPerSecond: RENDER_VIDEO_BPS,
            timesliceMs: 500,
            onChunk: async (blob) => {
              const b64 = await blobToBase64(blob);
              await send(b64);
            },
          });
        }
      }
    })();

    return () => {
      alive = false;
      abort.abort();
      if (statusTimer !== null) window.clearInterval(statusTimer);
      mixer?.dispose();
      mixer?.canvas.remove();
    };
  }, [showId, token]);

  return (
    <div className="fixed inset-0 overflow-hidden bg-black">
      <div ref={host} className="size-full" style={{ aspectRatio: `${STUDIO_WIDTH}/${STUDIO_HEIGHT}` }} />
      {error && <p className="absolute right-2 bottom-2 left-2 rounded bg-destructive/80 px-3 py-1 text-sm text-white">{error}</p>}
    </div>
  );
}
