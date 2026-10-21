/** AirBattleground's studio-link API (header X-Studio-Key). The key is only ever sent to `host`. */
import { HttpError } from "../../http.js";

export interface AbgMe {
  manager: { name: string };
  org: { name: string } | null;
}
export interface AbgMatch {
  id: string;
  title: string;
  subtitle: string;
  startsAt: string | null;
  status: "upcoming" | "live" | "done";
}
export interface AbgOutputs {
  livePage: boolean;
  siteYoutube: { channelTitle: string } | null;
  destinations: { id: string; name: string; kind: string }[];
}
export interface AbgBroadcastInput {
  matchId: string | null;
  title: string;
  livePage: boolean;
  siteYoutube: boolean;
  destinationIds: string[];
}
export interface AbgBroadcast {
  id: string;
  targets: { id: string; name: string; url: string }[];
  watchUrl: string | null;
}

const TIMEOUT_MS = 10_000;

export class StudioLinkClient {
  constructor(
    readonly host: string,
    private readonly key: string,
  ) {}

  private async call<T>(method: string, path: string, body?: unknown | FormData): Promise<T> {
    let res: Response;
    const headers: Record<string, string> = { "X-Studio-Key": this.key, Accept: "application/json" };
    let payload: BodyInit | undefined;
    if (body instanceof FormData) payload = body;
    else if (body !== undefined) {
      headers["Content-Type"] = "application/json";
      payload = JSON.stringify(body);
    }
    try {
      res = await fetch(`${this.host}${path}`, { method, headers, body: payload, signal: AbortSignal.timeout(TIMEOUT_MS), redirect: "error" });
    } catch {
      throw new HttpError(502, "INTEGRATION_UNREACHABLE", "Can't reach AirBattleground. Check the internet connection.");
    }
    if (res.status === 401 || res.status === 403) {
      throw new HttpError(502, "INTEGRATION_KEY_INVALID", "AirBattleground didn't accept this studio's key. Connect again with a new QR code.");
    }
    if (!res.ok) {
      const err = (await res.json().catch(() => null)) as { error?: { message?: string } } | null;
      throw new HttpError(502, "INTEGRATION_ERROR", err?.error?.message ? `AirBattleground: ${err.error.message}` : `AirBattleground answered with an error (${res.status}). Try again.`);
    }
    if (res.status === 204) return undefined as T;
    return (await res.json().catch(() => {
      throw new HttpError(502, "INTEGRATION_ERROR", "AirBattleground sent an answer the studio doesn't understand.");
    })) as T;
  }

  me() {
    return this.call<AbgMe>("GET", "/api/studio-link/me");
  }
  matches() {
    return this.call<{ items: AbgMatch[] }>("GET", "/api/studio-link/matches");
  }
  outputs() {
    return this.call<AbgOutputs>("GET", "/api/studio-link/outputs");
  }
  startBroadcast(input: AbgBroadcastInput) {
    return this.call<AbgBroadcast>("POST", "/api/studio-link/broadcasts", input);
  }
  heartbeat(id: string, status: { state: string; fps: number | null; bitrateKbps: number | null }) {
    return this.call<{ stop: boolean }>("POST", `/api/studio-link/broadcasts/${encodeURIComponent(id)}/heartbeat`, status);
  }
  stopBroadcast(id: string) {
    return this.call<void>("POST", `/api/studio-link/broadcasts/${encodeURIComponent(id)}/stop`);
  }
  screenshots(matchId: string, kind: string, png: Buffer) {
    const form = new FormData();
    form.append("files", new Blob([new Uint8Array(png)], { type: "image/png" }), "capture.png");
    form.append("kind", kind);
    return this.call<{ count: number }>("POST", `/api/studio-link/matches/${encodeURIComponent(matchId)}/screenshots`, form);
  }
}
