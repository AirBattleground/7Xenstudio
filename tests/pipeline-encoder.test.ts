import { describe, expect, it } from "vitest";
import {
  candidates,
  escapeTeeUrl,
  ffmpegArgs,
  outputArgs,
  parseEncoders,
  probeEncoder,
  ProgressMeter,
  teeTarget,
  videoArgs,
  type ProbeRunner,
} from "../src/server/pipeline/encoder.js";
import { parseSlaveFailure, redactKeys } from "../src/server/pipeline/ffmpeg.js";

const o = { fps: 60, kbps: 6000, cores: 8 };
const after = (args: string[], flag: string) => args[args.indexOf(flag) + 1];

describe("videoArgs", () => {
  it("libx264: CBR, keyframes every 2 s, yuv420p, 720p at the show fps", () => {
    const a = videoArgs("libx264", o);
    expect(after(a, "-c:v")).toBe("libx264");
    expect(after(a, "-preset")).toBe("veryfast");
    expect(after(a, "-b:v")).toBe("6000k");
    expect(after(a, "-maxrate")).toBe("6000k");
    expect(after(a, "-bufsize")).toBe("12000k");
    expect(after(a, "-g")).toBe("120");
    expect(after(a, "-force_key_frames")).toBe("expr:gte(t,n_forced*2)");
    expect(after(a, "-pix_fmt")).toBe("yuv420p");
    expect(after(a, "-s")).toBe("1280x720");
    expect(after(a, "-r")).toBe("60");
    expect(after(a, "-x264-params")).toContain("nal-hrd=cbr");
  });
  it("libx264 uses 'faster' only on 16+ cores", () => {
    expect(after(videoArgs("libx264", { ...o, cores: 16 }), "-preset")).toBe("faster");
    expect(after(videoArgs("libx264", { ...o, cores: 12 }), "-preset")).toBe("veryfast");
  });
  it.each([
    ["h264_nvenc", ["-rc", "cbr"]],
    ["h264_qsv", ["-look_ahead", "0"]],
    ["h264_amf", ["-rc", "cbr"]],
    ["h264_videotoolbox", ["-realtime", "1"]],
  ])("%s: hardware args + nv12", (enc, pair) => {
    const a = videoArgs(enc, { ...o, fps: 30, kbps: 4500 });
    expect(after(a, "-c:v")).toBe(enc);
    expect(after(a, pair[0]!)).toBe(pair[1]);
    expect(after(a, "-pix_fmt")).toBe("nv12");
    expect(after(a, "-g")).toBe("60");
    expect(after(a, "-r")).toBe("30");
    expect(after(a, "-bufsize")).toBe("9000k");
  });
  it("an unknown override is passed through", () => {
    expect(after(videoArgs("h264_vaapi", o), "-c:v")).toBe("h264_vaapi");
  });
  it("candidates per platform, libx264 last", () => {
    expect(candidates("darwin")).toEqual(["h264_videotoolbox", "libx264"]);
    expect(candidates("linux").at(-1)).toBe("libx264");
    expect(candidates("win32")).toEqual(["h264_nvenc", "h264_qsv", "h264_amf", "libx264"]);
  });
});

describe("ffmpegArgs", () => {
  it("WebM on stdin, explicit maps, AAC, progress, tee with global headers", () => {
    const a = ffmpegArgs("libx264", { ...o, slaves: [{ kind: "record", url: "/rec/a.mp4" }, { kind: "rtmp", url: "rtmp://h/live/key" }] });
    expect(a.join(" ")).toContain("-f webm -i pipe:0 -map 0:v:0 -map 0:a:0?");
    expect(a.join(" ")).toContain("-c:a aac -b:a 160k -ar 48000 -ac 2");
    expect(a.join(" ")).toContain("-progress pipe:1 -stats_period 2");
    expect(a.slice(-5)).toEqual(["-flags", "+global_header", "-f", "tee", expect.stringContaining("|")]);
  });
  it("no outputs → null muxer", () => {
    expect(outputArgs([])).toEqual(["-f", "null", "-"]);
  });
  it("one output still uses tee (stable slave indexes)", () => {
    expect(outputArgs([{ kind: "rtmp", url: "rtmp://x/y" }])).toContain("tee");
  });
});

describe("tee builder", () => {
  it("record → fragmented MP4 slave, rtmp/preview → flv slaves", () => {
    expect(
      teeTarget([
        { kind: "record", url: "/data/recordings/a.mp4" },
        { kind: "rtmp", url: "rtmp://a.rtmp.youtube.com/live2/abcd" },
        { kind: "preview", url: "rtmp://127.0.0.1:1940/live/show_1" },
      ]),
    ).toBe(
      "[f=mp4:movflags=+frag_keyframe+empty_moov+default_base_moof:onfail=ignore]/data/recordings/a.mp4" +
        "|[f=flv:onfail=ignore:flvflags=no_duration_filesize]rtmp://a.rtmp.youtube.com/live2/abcd" +
        "|[f=flv:onfail=ignore:flvflags=no_duration_filesize]rtmp://127.0.0.1:1940/live/show_1",
    );
  });
  it("escapes the tee special characters", () => {
    expect(escapeTeeUrl("rtmp://h/app/k|e[y]'\\")).toBe("rtmp://h/app/k\\|e\\[y\\]\\'\\\\");
    expect(teeTarget([{ kind: "rtmp", url: "rtmp://h/a/x|y" }])).toBe("[f=flv:onfail=ignore:flvflags=no_duration_filesize]rtmp://h/a/x\\|y");
    expect(teeTarget([{ kind: "record", url: "C:\\Rec\\a.mp4" }])).toContain("C:\\\\Rec\\\\a.mp4");
  });
  it("a Facebook rtmps URL with query string survives", () => {
    expect(teeTarget([{ kind: "rtmp", url: "rtmps://live-api-s.facebook.com:443/rtmp/FB-1?s_bl=1&a=b" }])).toContain(
      "]rtmps://live-api-s.facebook.com:443/rtmp/FB-1?s_bl=1&a=b",
    );
  });
});

describe("probeEncoder", () => {
  const encodersList = " V....D libx264  x\n V....D h264_nvenc  nv\n V....D h264_qsv  q\n";
  it("picks the first candidate that encodes one frame", async () => {
    const calls: string[] = [];
    const run: ProbeRunner = async (_p, args) => {
      if (args.includes("-encoders")) return { ok: true, stdout: encodersList, stderr: "" };
      const enc = after(args, "-c:v")!;
      calls.push(enc);
      return enc === "h264_qsv" ? { ok: true, stdout: "", stderr: "" } : { ok: false, stdout: "", stderr: "No device\nmore" };
    };
    const d = await probeEncoder("ffmpeg", { platform: "linux", run });
    expect(d.encoder).toBe("h264_qsv");
    expect(calls).toEqual(["h264_nvenc", "h264_qsv"]);
    expect(d.skipped).toEqual({ h264_nvenc: "No device" });
  });
  it("falls back to libx264; skips encoders not built in", async () => {
    const run: ProbeRunner = async (_p, args) =>
      args.includes("-encoders") ? { ok: true, stdout: " V....D libx264 x\n", stderr: "" } : { ok: after(args, "-c:v") === "libx264", stdout: "", stderr: "" };
    const d = await probeEncoder("ffmpeg", { platform: "linux", run });
    expect(d.encoder).toBe("libx264");
    expect(d.skipped.h264_nvenc).toBe("not in this ffmpeg build");
  });
  it("uses an override even when its probe fails", async () => {
    const run: ProbeRunner = async () => ({ ok: false, stdout: "", stderr: "Unknown encoder 'h264_foo'" });
    expect(await probeEncoder("ffmpeg", { override: "h264_foo", run })).toEqual({ encoder: "h264_foo", skipped: { h264_foo: "Unknown encoder 'h264_foo'" } });
  });
  it("throws a plain message when ffmpeg is missing", async () => {
    const run: ProbeRunner = async () => ({ ok: false, stdout: "", stderr: "spawn ffmpeg ENOENT" });
    await expect(probeEncoder("ffmpeg", { run })).rejects.toThrow(/ffmpeg was not found/);
  });
  it("parses ffmpeg -encoders", () => {
    expect([...parseEncoders(" ------\n V....D libx264              libx264 H.264\n A....D aac  AAC\n")]).toEqual(["libx264", "aac"]);
  });
});

describe("ProgressMeter", () => {
  it("kbps from total_size deltas, fps from frame deltas, out_time advancing", () => {
    let t = 0;
    const m = new ProgressMeter(() => t);
    expect(m.feed("frame=0\nout_time_us=0\ntotal_size=0\nprogress=continue\n")).toBe(true);
    expect(m.advancing).toBe(false);
    t = 2000;
    m.feed("frame=120\nout_time_us=2000000\ntotal_size=1500000\nprogr");
    expect(m.feed("ess=continue\n")).toBe(true);
    expect(m.kbps).toBe(6000);
    expect(m.fps).toBe(60);
    expect(m.advancing).toBe(true);
    expect(m.outSeconds).toBe(2);
    t = 4000;
    m.feed("frame=120\nout_time_us=2000000\ntotal_size=N/A\nprogress=continue\n");
    expect(m.advancing).toBe(false);
  });
  it("total_size N/A (tee) leaves kbps null", () => {
    const m = new ProgressMeter(() => 0);
    m.feed("frame=10\nfps=59.9\nbitrate=N/A\ntotal_size=N/A\nout_time_us=100000\nprogress=continue\n");
    expect(m.kbps).toBeNull();
    expect(m.fps).toBe(59.9);
  });
});

describe("ffmpeg stderr", () => {
  it("parses tee slave failures", () => {
    expect(parseSlaveFailure("[tee @ 0x1] Slave muxer #1 failed: Connection refused, continuing with 1/2 slaves.")).toEqual({ index: 1, error: "Connection refused" });
    expect(parseSlaveFailure("[tee @ 0x1] Slave muxer #0 failed: Broken pipe")).toEqual({ index: 0, error: "Broken pipe" });
    expect(parseSlaveFailure("something else")).toBeNull();
  });
  it("redacts stream keys", () => {
    expect(redactKeys("Error rtmp://a.rtmp.youtube.com/live2/abcd-efgh-1234: refused")).toBe("Error rtmp://a.rtmp.youtube.com/live2/…: refused");
  });
});
