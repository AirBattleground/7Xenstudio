/** Slot rectangles for each scene layout on the 1280×720 studio canvas. */
import { STUDIO_HEIGHT as H, STUDIO_WIDTH as W } from "@shared/types";
import type { LayoutKind } from "./types";

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
  /** drawn with a border + rounded corners (insets) */
  framed?: boolean;
}

const G = 16; // gap

export const LAYOUTS: Record<LayoutKind, { label: string; slots: number; slotNames: string[]; rects: Rect[] }> = {
  full: { label: "Full screen", slots: 1, slotNames: ["Main"], rects: [{ x: 0, y: 0, w: W, h: H }] },
  side: {
    label: "Side by side",
    slots: 2,
    slotNames: ["Left", "Right"],
    rects: [
      { x: G, y: (H - (W / 2 - 1.5 * G) * (9 / 16)) / 2, w: W / 2 - 1.5 * G, h: (W / 2 - 1.5 * G) * (9 / 16), framed: true },
      { x: W / 2 + G / 2, y: (H - (W / 2 - 1.5 * G) * (9 / 16)) / 2, w: W / 2 - 1.5 * G, h: (W / 2 - 1.5 * G) * (9 / 16), framed: true },
    ],
  },
  pip: {
    label: "Picture in picture",
    slots: 2,
    slotNames: ["Main", "Inset"],
    rects: [
      { x: 0, y: 0, w: W, h: H },
      { x: W - 360 - 24, y: H - 203 - 24, w: 360, h: 203, framed: true },
    ],
  },
  desk: {
    label: "Host desk",
    slots: 2,
    slotNames: ["Game", "Host"],
    rects: [
      { x: G, y: G, w: 880, h: 495, framed: true },
      { x: 880 + 2 * G, y: G, w: W - 880 - 3 * G, h: 495, framed: true },
    ],
  },
  trio: {
    label: "One big, two small",
    slots: 3,
    slotNames: ["Big", "Top", "Bottom"],
    rects: [
      { x: G, y: G, w: 840, h: H - 2 * G, framed: true },
      { x: 840 + 2 * G, y: G, w: W - 840 - 3 * G, h: (H - 3 * G) / 2, framed: true },
      { x: 840 + 2 * G, y: G + (H - 3 * G) / 2 + G, w: W - 840 - 3 * G, h: (H - 3 * G) / 2, framed: true },
    ],
  },
};
