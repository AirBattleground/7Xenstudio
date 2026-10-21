/**
 * Integrations (optional connections to other services). The core only knows this interface; each integration lives
 * in its own folder (src/server/integrations/<id>/). Delete the folder and its line in INTEGRATIONS and the studio
 * still builds and works.
 */
import type { CaptureKind, IntegrationInfo, IntegrationOutput, Show, StudioEvent } from "../../shared/types.js";
import { createAirBattleground } from "./airbattleground/index.js";

export interface IntegrationTarget {
  id: string;
  name: string;
  /** full RTMP(S) URL */
  url: string;
}

export interface BroadcastStatus {
  state: "live" | "starting" | "error";
  fps: number | null;
  bitrateKbps: number | null;
}

export interface Integration {
  readonly id: string;
  readonly name: string;
  /** cheap: no network */
  info(): IntegrationInfo;
  /** `link` = scanned QR text / pasted link or key. Throws HttpError with a user-facing message. */
  connect(link: string): Promise<IntegrationInfo>;
  disconnect(): Promise<void>;
  events(): Promise<StudioEvent[]>;
  outputs(): Promise<IntegrationOutput[]>;
  startBroadcast(show: Show): Promise<{ broadcastId: string; targets: IntegrationTarget[]; watchUrl: string | null }>;
  heartbeat(broadcastId: string, status: BroadcastStatus): Promise<{ stop: boolean }>;
  stopBroadcast(broadcastId: string): Promise<void>;
  capture(eventId: string, kind: CaptureKind, png: Buffer): Promise<void>;
  /** stop background work (timers); called on shutdown */
  dispose?(): void;
}

/** What an integration gets from the core: its own slot in the store. */
export interface IntegrationContext {
  state<T>(): T | null;
  setState(value: unknown): void;
}

export type IntegrationFactory = (ctx: IntegrationContext) => Integration;

export const INTEGRATIONS: IntegrationFactory[] = [createAirBattleground];

export class IntegrationRegistry {
  readonly items: Integration[];
  constructor(ctxFor: (id: string) => IntegrationContext, factories: IntegrationFactory[] = INTEGRATIONS) {
    // the id is only known after construction, so the context resolves it lazily
    this.items = factories.map((f) => {
      let id = "";
      const it = f({ state: <T,>() => ctxFor(id).state<T>(), setState: (v) => ctxFor(id).setState(v) });
      id = it.id;
      return it;
    });
  }
  get(id: string): Integration | undefined {
    return this.items.find((i) => i.id === id);
  }
  dispose() {
    for (const i of this.items) i.dispose?.();
  }
}
