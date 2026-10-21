import { describe, expect, it } from "vitest";
import { DEFAULT_OVERLAYS, type Scene } from "@shared/types";
import { defaultConfig, fadeMsOf, goLiveMode, normalizeConfig, resolveScene, resolveSceneForRender, sceneForKey } from "../src/web/engine/config";
import { sourceKey } from "../src/web/engine/types";
import { cacheBust, pickCaptureMime } from "../src/web/engine/mixer";
import { dataUrlToBase64 } from "../src/web/lib/base64";
import { encoderLabel, formatBytes, formatDuration } from "../src/web/lib/format";
import { withToken } from "../src/web/lib/render-token";
import { maskKey, parseConnectLink } from "../src/web/integrations/airbattleground/link";

describe("config", () => {
  it("default config has the four starter scenes", () => {
    const c = defaultConfig();
    expect(c.scenes.map((s) => s.name)).toEqual(["Starting soon", "Phone", "Host", "Break"]);
    expect(c.overlays).toEqual(DEFAULT_OVERLAYS);
  });

  it("normalizes partial overlays and bad configs", () => {
    const c = normalizeConfig({ v: 1, scenes: [], overlays: { liveBug: false, logo: { on: true } }, transition: "cut" });
    expect(c.overlays.liveBug).toBe(false);
    expect(c.overlays.logo).toEqual({ on: true, propId: null, corner: "tr" });
    expect(c.overlays.web).toEqual({ on: false, url: "" });
    expect(c.transition).toBe("cut");
    expect(normalizeConfig(null).scenes.length).toBe(4);
    expect(normalizeConfig({ v: 2 }).v).toBe(1);
  });

  const scene: Scene = { id: "a", name: "A", layout: "desk", slots: [{ kind: "slate" }, { kind: "camera" }] };
  it("slate plays the intro prop", () => {
    expect(resolveScene(scene, "p1").slots[0]).toEqual({ kind: "prop", id: "p1" });
    expect(resolveScene(scene, null).slots[0]).toEqual({ kind: "slate" });
  });
  it("render page shows the slate instead of the webcam", () => {
    expect(resolveSceneForRender(scene, null).slots).toEqual([{ kind: "slate" }, { kind: "slate" }]);
  });

  it("fade length, go-live mode and scene keys", () => {
    expect(fadeMsOf({ transition: "fade" })).toBe(600);
    expect(fadeMsOf({ transition: "cut" })).toBe(0);
    expect(goLiveMode({ record: true, destinationIds: [] }, [])).toBe("record");
    expect(goLiveMode({ record: true, destinationIds: ["d"] }, [])).toBe("live");
    expect(goLiveMode({ record: false, destinationIds: [] }, ["abg:live-page"])).toBe("live");
    expect(goLiveMode({ record: false, destinationIds: [] }, [])).toBe("none");
    const scenes = defaultConfig().scenes;
    expect(sceneForKey(scenes, "2")).toBe(scenes[1]);
    expect(sceneForKey(scenes, "9")).toBeNull();
    expect(sceneForKey(scenes, "0")).toBeNull();
  });

  it("source keys", () => {
    expect(sourceKey({ kind: "device", id: "x" })).toBe("device:x");
    expect(sourceKey({ kind: "web", url: "https://a/b.png" })).toBe("web:https://a/b.png");
    expect(sourceKey({ kind: "camera" })).toBe("camera:");
  });
});

describe("render page helpers", () => {
  it("cuts base64 after ;base64, even when the MIME has commas", () => {
    expect(dataUrlToBase64("data:video/webm;codecs=vp8,opus;base64,QUJD")).toBe("QUJD");
    expect(dataUrlToBase64("garbage")).toBe("");
  });
  it("adds the token to same-origin media URLs only", () => {
    expect(withToken("/api/props/1/file", "tok")).toBe("/api/props/1/file?t=tok");
    expect(withToken("/a?x=1", "t k")).toBe("/a?x=1&t=t%20k");
    expect(withToken("https://other.example/x.png", "tok")).toBe("https://other.example/x.png");
    expect(withToken("/a", null)).toBe("/a");
  });
  it("prefers H.264 for capture", () => {
    expect(pickCaptureMime(() => true)).toBe("video/webm;codecs=h264,opus");
    expect(pickCaptureMime((m) => m.includes("vp8"))).toBe("video/webm;codecs=vp8,opus");
    expect(pickCaptureMime(() => false)).toBe("video/webm");
  });
  it("cache-busts polled image URLs", () => {
    expect(cacheBust("https://x/s.png", 5)).toBe("https://x/s.png?_sw=5");
    expect(cacheBust("https://x/s.png?a=1#f", 5)).toBe("https://x/s.png?a=1&_sw=5#f");
    expect(cacheBust("data:image/png;base64,AA", 5)).toBe("data:image/png;base64,AA");
  });
});

describe("format", () => {
  it("bytes, durations, encoder", () => {
    expect(formatBytes(0)).toBe("0 B");
    expect(formatBytes(1536)).toBe("1.5 KB");
    expect(formatBytes(5 * 1024 ** 3)).toBe("5.0 GB");
    expect(formatDuration(65)).toBe("1:05");
    expect(formatDuration(3725)).toBe("1:02:05");
    expect(encoderLabel("h264_nvenc")).toEqual({ gpu: true, label: "NVENC" });
    expect(encoderLabel("libx264")).toEqual({ gpu: false, label: "CPU" });
    expect(encoderLabel(null)).toBeNull();
  });
});

describe("connect link (integration)", () => {
  it("accepts the scanned link or a bare key", () => {
    expect(parseConnectLink("7xen-studio://connect?host=https%3A%2F%2Fairbattleground.com&key=sw_abcdef123456")).toEqual({ host: "https://airbattleground.com", key: "sw_abcdef123456" });
    expect(parseConnectLink("  7xen-studio://connect?host=https://example.com/&key=sw_abcdefgh  ")).toEqual({ host: "https://example.com", key: "sw_abcdefgh" });
    expect(parseConnectLink("sw_abcdefgh12")).toEqual({ host: null, key: "sw_abcdefgh12" });
  });
  it("rejects anything else", () => {
    expect(parseConnectLink("")).toBeNull();
    expect(parseConnectLink("hello")).toBeNull();
    expect(parseConnectLink("7xen-studio://connect?host=https://x.com&key=nope")).toBeNull();
    expect(parseConnectLink("7xen-studio://connect?host=ftp://x.com&key=sw_abcdefgh")).toBeNull();
    expect(parseConnectLink("7xen://pair?host=x&key=sw_abcdefgh")).toBeNull();
  });
  it("masks keys", () => {
    expect(maskKey("sw_abcdefghijklmnop")).toBe("sw_abcd…mnop");
  });
});
