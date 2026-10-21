/** The AirBattleground integration: link a show to a match, stream to its Live page / YouTube / keys, upload stills. */
import type { CaptureKind, IntegrationInfo, IntegrationOutput, Show, StudioEvent } from "../../../shared/types.js";
import { HttpError } from "../../http.js";
import type { Integration, IntegrationContext } from "../registry.js";
import { StudioLinkClient } from "./client.js";
import { parseConnectLink } from "./link.js";

export const ABG_ID = "airbattleground";
export const OUT_LIVE_PAGE = "abg:live-page";
export const OUT_YOUTUBE = "abg:youtube";
export const OUT_KEY_PREFIX = "abg:key:";

interface AbgState {
  host: string;
  key: string;
  account: { name: string; org: string | null } | null;
}

export function broadcastInput(show: Show) {
  const ids = show.link?.outputIds ?? [];
  return {
    matchId: show.link?.eventId ?? null,
    title: show.title,
    livePage: ids.includes(OUT_LIVE_PAGE),
    siteYoutube: ids.includes(OUT_YOUTUBE),
    destinationIds: ids.filter((i) => i.startsWith(OUT_KEY_PREFIX)).map((i) => i.slice(OUT_KEY_PREFIX.length)),
  };
}

/** while connected, GET /me about this often: AirBattleground shows the studio Online (Offline after 30 s of silence) */
export const PRESENCE_MS = 20_000;

export function createAirBattleground(ctx: IntegrationContext): Integration {
  let lastError: string | null = null;
  let lastCallAt = 0;

  const client = () => {
    const s = ctx.state<AbgState>();
    if (!s) throw new HttpError(409, "INTEGRATION_NOT_CONNECTED", "Connect AirBattleground first.");
    return new StudioLinkClient(s.host, s.key);
  };
  /** remember the last failure for info(); clear it on success */
  const track = async <T,>(p: Promise<T>): Promise<T> => {
    try {
      const v = await p;
      lastCallAt = Date.now();
      lastError = null;
      return v;
    } catch (e) {
      lastError = e instanceof HttpError ? e.message : "AirBattleground isn't answering.";
      throw e;
    }
  };

  const info = (): IntegrationInfo => {
    const s = ctx.state<AbgState>();
    return { id: ABG_ID, name: "AirBattleground", connected: !!s, account: s?.account ?? null, host: s?.host ?? null, error: s ? lastError : null };
  };

  // presence ping: any call counts, so only ping when nothing else talked to AirBattleground lately (heartbeats do while live)
  const presence = setInterval(() => {
    const s = ctx.state<AbgState>();
    if (!s || Date.now() - lastCallAt < PRESENCE_MS - 1_000) return;
    track(new StudioLinkClient(s.host, s.key).me())
      .then((me) => {
        const cur = ctx.state<AbgState>();
        const account = { name: me.manager?.name ?? "Manager", org: me.org?.name ?? null };
        if (cur && cur.key === s.key && JSON.stringify(cur.account) !== JSON.stringify(account)) ctx.setState({ ...cur, account });
      })
      .catch(() => {});
  }, 5_000);
  presence.unref?.();

  return {
    id: ABG_ID,
    name: "AirBattleground",
    info,

    async connect(link) {
      const parsed = parseConnectLink(link);
      if (!parsed) throw new HttpError(400, "VALIDATION_ERROR", "That isn't an AirBattleground studio link. Scan the QR again or paste the key (it starts with sw_).", { link: "Not a studio link" });
      const me = await new StudioLinkClient(parsed.host, parsed.key).me();
      lastError = null;
      lastCallAt = Date.now();
      ctx.setState({ host: parsed.host, key: parsed.key, account: { name: me.manager?.name ?? "Manager", org: me.org?.name ?? null } } satisfies AbgState);
      return info();
    },

    async disconnect() {
      lastError = null;
      ctx.setState(null);
    },

    async events(): Promise<StudioEvent[]> {
      const { items } = await track(client().matches());
      return (items ?? []).map((m) => ({ id: String(m.id), title: m.title, subtitle: m.subtitle ?? "", startsAt: m.startsAt ?? null, status: m.status }));
    },

    async outputs(): Promise<IntegrationOutput[]> {
      const o = await track(client().outputs());
      const out: IntegrationOutput[] = [];
      if (o.livePage) out.push({ id: OUT_LIVE_PAGE, name: "AirBattleground Live page", kind: "live-page", defaultOn: true });
      if (o.siteYoutube) out.push({ id: OUT_YOUTUBE, name: `YouTube: ${o.siteYoutube.channelTitle}`, kind: "youtube", defaultOn: false });
      for (const d of o.destinations ?? []) out.push({ id: `${OUT_KEY_PREFIX}${d.id}`, name: d.name, kind: "rtmp", defaultOn: false });
      return out;
    },

    async startBroadcast(show) {
      const b = await track(client().startBroadcast(broadcastInput(show)));
      return { broadcastId: String(b.id), targets: b.targets ?? [], watchUrl: b.watchUrl ?? null };
    },

    async heartbeat(id, status) {
      const r = await track(client().heartbeat(id, status));
      return { stop: !!r?.stop };
    },

    async stopBroadcast(id) {
      await track(client().stopBroadcast(id));
    },

    async capture(eventId: string, kind: CaptureKind, png: Buffer) {
      await track(client().screenshots(eventId, kind, png));
    },

    dispose() {
      clearInterval(presence);
    },
  };
}
