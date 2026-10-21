/** Pure helpers for a show's config (no browser APIs — unit-tested). */
import { DEFAULT_OVERLAYS, type Overlays, type Scene, type ShowConfig, type SourceRef } from "@shared/types";

/** Short random id for scenes. */
export const sid = () => Math.random().toString(36).slice(2, 9);

/** A first setup when a show has no scenes yet. */
export function defaultConfig(): ShowConfig {
  return {
    v: 1,
    scenes: [
      { id: sid(), name: "Starting soon", layout: "full", slots: [{ kind: "slate" }] },
      { id: sid(), name: "Phone", layout: "full", slots: [null] },
      { id: sid(), name: "Host", layout: "full", slots: [{ kind: "camera" }] },
      { id: sid(), name: "Break", layout: "full", slots: [{ kind: "slate" }] },
    ],
    overlays: { ...DEFAULT_OVERLAYS, logo: { ...DEFAULT_OVERLAYS.logo }, web: { ...DEFAULT_OVERLAYS.web } },
    transition: "fade",
    introPropId: null,
  };
}

/** The saved config with every overlay field present (older/partial configs get the defaults). */
export function normalizeConfig(raw: unknown): ShowConfig {
  const c = raw as Partial<ShowConfig> | null | undefined;
  if (!c || c.v !== 1 || !Array.isArray(c.scenes)) return defaultConfig();
  const o = (c.overlays ?? {}) as Partial<Overlays>;
  return {
    v: 1,
    scenes: c.scenes.map((s) => ({ ...s, slots: Array.isArray(s.slots) ? s.slots : [] })),
    overlays: {
      ...DEFAULT_OVERLAYS,
      ...o,
      logo: { ...DEFAULT_OVERLAYS.logo, ...(o.logo ?? {}) },
      web: { ...DEFAULT_OVERLAYS.web, ...(o.web ?? {}) },
    },
    transition: c.transition === "cut" ? "cut" : "fade",
    introPropId: c.introPropId ?? null,
  };
}

/** The "Starting soon" slate plays the intro prop video when one is picked. */
export function resolveScene(s: Scene, introPropId: string | null): Scene {
  return { ...s, slots: s.slots.map((x) => (x?.kind === "slate" && introPropId ? { kind: "prop", id: introPropId } : x)) };
}

/** On the render page (headless Chrome on the studio PC) there's no webcam: camera slots show the slate. */
export function resolveSceneForRender(s: Scene, introPropId: string | null): Scene {
  const slate: SourceRef = { kind: "slate" };
  const r = resolveScene(s, introPropId);
  return { ...r, slots: r.slots.map((x) => (x?.kind === "camera" ? slate : x)) };
}

/** Transition length of a take. */
export const fadeMsOf = (c: Pick<ShowConfig, "transition">) => (c.transition === "fade" ? 600 : 0);

/** What the main button does with these outputs on: record only, or go live (anything streams). */
export function goLiveMode(outputs: { record: boolean; destinationIds: string[] }, integrationOutputIds: string[]): "record" | "live" | "none" {
  const streams = outputs.destinationIds.length + integrationOutputIds.length;
  if (streams > 0) return "live";
  return outputs.record ? "record" : "none";
}

/** Scene that matches keyboard key "1".."9" (null when none). */
export function sceneForKey(scenes: Scene[], key: string): Scene | null {
  if (!/^[1-9]$/.test(key)) return null;
  return scenes[Number(key) - 1] ?? null;
}
