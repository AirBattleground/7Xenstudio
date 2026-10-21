/**
 * Studio show setup (the show's `config`, version 1, see src/shared/types.ts). Scenes are frames (layouts) whose
 * slots are filled with sources; overlays sit on top of whatever scene is on air.
 */
export type { LayoutKind, Overlays, Scene, ShowConfig, SourceRef } from "@shared/types";
export { DEFAULT_OVERLAYS } from "@shared/types";
import type { SourceRef } from "@shared/types";

/** A stable key per source (two slots with the same phone share one player). */
export const sourceKey = (s: SourceRef): string => `${s.kind}:${"id" in s ? s.id : "url" in s ? s.url : ""}`;

export const sameSource = (a: SourceRef | null, b: SourceRef | null) => !!a && !!b && sourceKey(a) === sourceKey(b);
