import path from "node:path";
import { describe, expect, it } from "vitest";
import { GrowthRate, plainOutputError, publishPlan, slugify } from "../src/server/pipeline/index.js";
import { recordingFileName } from "../src/server/pipeline/types.js";

const at = new Date(2026, 9, 21, 19, 5, 7);

describe("recording naming", () => {
  it("<YYYY-MM-DD_HH-mm-ss>_<slug>_<showId>.mp4 in local time", () => {
    expect(recordingFileName("evening-show", "abc123", at)).toBe("2026-10-21_19-05-07_evening-show_abc123.mp4");
    expect(recordingFileName("", "abc", at)).toBe("2026-10-21_19-05-07_show_abc.mp4");
  });
  it("slugify", () => {
    expect(slugify("  Evening Show: Finals #2! ")).toBe("evening-show-finals-2");
    expect(slugify("!!!")).toBe("show");
  });
});

describe("publishPlan", () => {
  const base = { showId: "s1", title: "Evening Show", slug: "evening-show" };
  it("record target (a directory) → a fresh file per start; rtmp/preview URLs as given; ids follow slave order", () => {
    const p = publishPlan(
      {
        ...base,
        targets: [
          { id: "rec", name: "Recording", kind: "record", url: "/data/recordings" },
          { id: "yt", name: "YouTube", kind: "rtmp", url: "rtmp://a.rtmp.youtube.com/live2/key" },
          { id: "pv", name: "Program out", kind: "preview", url: "rtmp://127.0.0.1:1940/live/show_s1" },
        ],
      },
      at,
    );
    const file = path.join("/data/recordings", "2026-10-21_19-05-07_evening-show_s1.mp4");
    expect(p.recordingPath).toBe(file);
    expect(p.slaves).toEqual([
      { kind: "record", url: file },
      { kind: "rtmp", url: "rtmp://a.rtmp.youtube.com/live2/key" },
      { kind: "preview", url: "rtmp://127.0.0.1:1940/live/show_s1" },
    ]);
    expect(p.ids).toEqual(["rec", "yt", "pv"]);
    expect(publishPlan({ ...base, targets: [{ id: "rec", name: "R", kind: "record", url: "/d" }] }, new Date(2026, 9, 21, 19, 5, 11)).recordingPath).toContain("19-05-11");
  });
  it("drops duplicate URLs; no record target → no recording", () => {
    const p = publishPlan({
      ...base,
      targets: [
        { id: "a", name: "A", kind: "rtmp", url: "rtmp://h/a/k" },
        { id: "b", name: "B", kind: "rtmp", url: "rtmp://h/a/k" },
      ],
    });
    expect(p.ids).toEqual(["a"]);
    expect(p.recordingPath).toBeNull();
  });
});

describe("helpers", () => {
  it("GrowthRate: kbps over a window, null until 3 s of growth", () => {
    let t = 0;
    const g = new GrowthRate(10_000, () => t);
    g.add(0);
    t = 2000;
    g.add(1_500_000);
    expect(g.kbps()).toBeNull();
    t = 4000;
    g.add(3_000_000);
    expect(g.kbps()).toBe(6000);
    g.reset();
    expect(g.kbps()).toBeNull();
  });
  it("plain output errors", () => {
    expect(plainOutputError("Connection refused")).toBe("The destination refused the connection");
    expect(plainOutputError("Broken pipe")).toBe("The destination dropped the connection");
  });
});
