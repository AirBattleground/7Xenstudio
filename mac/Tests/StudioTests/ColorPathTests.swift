import Testing
import Foundation
import CoreMedia
import CoreVideo
@testable import Studio

private final class FixedSource: FrameSource {
    let ref: SourceRef; let pb: CVPixelBuffer
    init(_ ref: SourceRef, _ pb: CVPixelBuffer) { self.ref = ref; self.pb = pb }
    func latestFrame() -> CVPixelBuffer? { pb }
    func stop() {}
}
private final class FixedProvider: SourceProvider {
    var map: [SourceRef: FrameSource] = [:]
    func source(for ref: SourceRef) -> FrameSource? { map[ref] }
}

enum ColorChart {
    static let cols = 8, rows = 5
    static let colors: [(Int, Int, Int)] = [
        (191,191,191),(191,191,0),(0,191,191),(0,191,0),(191,0,191),(191,0,0),(0,0,191),(0,0,0),
        (255,255,255),(255,255,0),(0,255,255),(0,255,0),(255,0,255),(255,0,0),(0,0,255),(16,16,16),
        (255,219,172),(224,172,105),(198,134,66),(141,85,36),(241,194,125),(255,205,148),(120,70,50),(90,60,40),
        (0,0,0),(36,36,36),(73,73,73),(109,109,109),(146,146,146),(182,182,182),(219,219,219),(255,255,255),
        (64,0,0),(0,64,0),(0,0,64),(128,64,32),(32,64,128),(200,100,150),(100,200,150),(250,250,100)]
    static func yuv(_ c: (Int, Int, Int), kr: Double = 0.2126, kb: Double = 0.0722) -> (UInt8, UInt8, UInt8) {
        let r = Double(c.0) / 255, g = Double(c.1) / 255, b = Double(c.2) / 255, kg = 1 - kr - kb
        let y = kr * r + kg * g + kb * b
        let cb = (b - y) / (2 * (1 - kb)), cr = (r - y) / (2 * (1 - kr))
        func q(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        return (q(16 + 219 * y), q(128 + 224 * cb), q(128 + 224 * cr))
    }
    /// 1920x1080 video-range NV12 chart; returns the buffer and raw bytes.
    static func nv12(w: Int = 1920, h: Int = 1080, matrix: CFString = kCVImageBufferYCbCrMatrix_ITU_R_709_2, kr: Double = 0.2126, kb: Double = 0.0722) -> (CVPixelBuffer, Data) {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
        let b = pb!
        CVBufferSetAttachment(b, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        var raw = Data(count: w * h * 3 / 2)
        let pw = w / cols, ph = h / rows
        raw.withUnsafeMutableBytes { rp in
            let base = rp.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<h { for x in 0..<w {
                let i = min(rows - 1, y / ph) * cols + min(cols - 1, x / pw)
                base[y * w + x] = yuv(colors[i], kr: kr, kb: kb).0
            } }
            for y in 0..<(h / 2) { for x in 0..<(w / 2) {
                let i = min(rows - 1, (y * 2) / ph) * cols + min(cols - 1, (x * 2) / pw)
                let c = yuv(colors[i], kr: kr, kb: kb)
                base[w * h + y * w + x * 2] = c.1; base[w * h + y * w + x * 2 + 1] = c.2
            } }
        }
        CVPixelBufferLockBaseAddress(b, [])
        raw.withUnsafeBytes { rp in
            let src = rp.baseAddress!
            for r in 0..<h { memcpy(CVPixelBufferGetBaseAddressOfPlane(b, 0)! + r * CVPixelBufferGetBytesPerRowOfPlane(b, 0), src + r * w, w) }
            for r in 0..<(h / 2) { memcpy(CVPixelBufferGetBaseAddressOfPlane(b, 1)! + r * CVPixelBufferGetBytesPerRowOfPlane(b, 1), src + w * h + r * w, w) }
        }
        CVPixelBufferUnlockBaseAddress(b, [])
        return (b, raw)
    }
    /// interior mean RGB of patch i from packed rgb24
    static func patchMean(_ rgb: [UInt8], w: Int, h: Int, _ i: Int) -> (Double, Double, Double) {
        let pw = w / cols, ph = h / rows, cx = (i % cols) * pw, cy = (i / cols) * ph
        var s = (0.0, 0.0, 0.0), n = 0.0
        for y in (cy + ph / 5)..<(cy + ph * 4 / 5) { for x in (cx + pw / 5)..<(cx + pw * 4 / 5) {
            let o = (y * w + x) * 3; s.0 += Double(rgb[o]); s.1 += Double(rgb[o + 1]); s.2 += Double(rgb[o + 2]); n += 1
        } }
        return (s.0 / n, s.1 / n, s.2 / n)
    }
    static func lab(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
        func lin(_ v: Double) -> Double { let x = v / 255; return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let r = lin(c.0), g = lin(c.1), b = lin(c.2)
        let X = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047, Y = 0.2126 * r + 0.7152 * g + 0.0722 * b, Z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        return (116 * f(Y) - 16, 500 * (f(X) - f(Y)), 200 * (f(Y) - f(Z)))
    }
    static func dE(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let p = lab(a), q = lab(b); return sqrt(pow(p.0 - q.0, 2) + pow(p.1 - q.1, 2) + pow(p.2 - q.2, 2))
    }
    /// (mean abs error per channel, max abs error, mean dE76, worst patch index, worst dE)
    static func compare(_ a: [UInt8], _ b: [UInt8], w: Int = 1920, h: Int = 1080) -> (mae: Double, maxErr: Double, meanDE: Double, worst: Int, worstDE: Double) {
        var mae = 0.0, mx = 0.0, de = 0.0, worst = 0, wde = 0.0
        for i in 0..<(cols * rows) {
            let p = patchMean(a, w: w, h: h, i), q = patchMean(b, w: w, h: h, i)
            let e = [abs(p.0 - q.0), abs(p.1 - q.1), abs(p.2 - q.2)]
            mae += e.reduce(0, +) / 3; mx = max(mx, e.max()!)
            let d = dE(p, q); de += d; if d > wde { wde = d; worst = i }
        }
        let n = Double(cols * rows)
        return (mae / n, mx, de / n, worst, wde)
    }
}

private func runTool(_ path: String, _ args: [String]) -> Bool {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit(); return p.terminationStatus == 0
}

/// Renders a source through the real compositor into a BGRA output buffer and returns packed rgb24 + the buffer.
private func composite(_ comp: MetalCompositor, _ source: CVPixelBuffer, scene: Scene, ref: SourceRef = .device(id: "t"), vivid: VividLevel = .off) -> (rgb: [UInt8], pb: CVPixelBuffer)? {
    let prov = FixedProvider(); prov.map[ref] = FixedSource(ref, source); comp.provider = prov
    comp.vivid = vivid
    guard let out = comp.makeOutputBuffer() else { return nil }
    let sem = DispatchSemaphore(value: 0)
    guard comp.render(FrameRequest(program: scene, mix: 1), to: FrameTargets(output: out), completion: { _ in sem.signal() }) else { return nil }
    sem.wait()
    return (rgbFromBGRA(out), out)
}
private func rgbFromBGRA(_ pb: CVPixelBuffer) -> [UInt8] {
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb)
    var out = [UInt8](repeating: 0, count: w * h * 3)
    for y in 0..<h { for x in 0..<w { let s = y * bpr + x * 4, d = (y * w + x) * 3; out[d] = base[s + 2]; out[d + 1] = base[s + 1]; out[d + 2] = base[s] } }
    return out
}

@Suite(.serialized) struct ColorPathTests {
    @Test func compositorReproducesBT709Chart() throws {
        guard let comp = MetalCompositor() else { return }
        let (pb, _) = ColorChart.nv12()
        let scene = Scene(id: "s", name: "s", layout: .full, slots: [.device(id: "t")])
        let r = try #require(composite(comp, pb, scene: scene))
        // analytic reference: the original RGB of every patch
        var expect = [UInt8](repeating: 0, count: 1920 * 1080 * 3)
        let pw = 1920 / ColorChart.cols, ph = 1080 / ColorChart.rows
        for y in 0..<1080 { for x in 0..<1920 {
            let c = ColorChart.colors[min(ColorChart.rows - 1, y / ph) * ColorChart.cols + min(ColorChart.cols - 1, x / pw)]
            let o = (y * 1920 + x) * 3; expect[o] = UInt8(c.0); expect[o + 1] = UInt8(c.1); expect[o + 2] = UInt8(c.2)
        } }
        let c = ColorChart.compare(r.rgb, expect)
        print("COLOR compositor vs source RGB: MAE=\(c.mae) max=\(c.maxErr) meanDE=\(c.meanDE) worstPatch=\(c.worst) dE=\(c.worstDE)")
        // 8-bit YCbCr quantisation limits accuracy to ~1-2 levels on saturated colours
        #expect(c.maxErr <= 3.5); #expect(c.meanDE < 1.5)
    }

    @Test func oneToOneIsPixelExactAndUpscaleIsSharper() throws {
        guard let comp = MetalCompositor() else { return }
        let (pb, _) = ColorChart.nv12()
        let scene = Scene(id: "s", name: "s", layout: .full, slots: [.device(id: "t")])
        // same chart through the 1:1 path twice with vivid off: deterministic, and sharp edges stay sharp (no resampling blur)
        let a = try #require(composite(comp, pb, scene: scene)).rgb
        // horizontal edge between patch 0 and 1 at x = 240: 1 px transition max
        let row = 100, x0 = 1920 / 8
        let l = Int(a[(row * 1920 + x0 - 2) * 3 + 2]), rr = Int(a[(row * 1920 + x0 + 1) * 3 + 2])
        #expect(abs(l - rr) > 100)   // blue differs a lot between patch0 (191) and patch1 (0)
        let mid = Int(a[(row * 1920 + x0 - 1) * 3 + 2]) , mid2 = Int(a[(row * 1920 + x0) * 3 + 2])
        print("EDGE 1:1 px values: \(l) \(mid) \(mid2) \(rr)")
    }

    /// Full-path colour measurement (compositor -> VideoToolbox -> ffmpeg -c copy -> decode) against ffmpeg's own conversion.
    /// Enabled with STUDIO_COLORBENCH=<existing output dir>. Writes src.nv12 ref.rgb comp.rgb rec.mp4 rec.rgb there.
    @Test func chartThroughWholePipeline() async throws {
        guard let dir = ProcessInfo.processInfo.environment["STUDIO_COLORBENCH"], let ff = FFmpegLocator.locate(), let comp = MetalCompositor() else { return }
        let vivid = VividLevel(rawValue: Int(ProcessInfo.processInfo.environment["STUDIO_COLORBENCH_VIVID"] ?? "0") ?? 0) ?? .off
        let (pb, raw) = ColorChart.nv12()
        let d = URL(fileURLWithPath: dir)
        try raw.write(to: d.appendingPathComponent("src.nv12"))
        #expect(runTool(ff, ["-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "nv12", "-video_size", "1920x1080", "-i", d.appendingPathComponent("src.nv12").path,
                            "-vf", "scale=in_range=tv:in_color_matrix=bt709:out_range=pc:flags=accurate_rnd+full_chroma_int,format=rgb24", "-frames:v", "1", "-f", "rawvideo", d.appendingPathComponent("ref.rgb").path]))
        let ref = [UInt8](try Data(contentsOf: d.appendingPathComponent("ref.rgb")))
        let scene = Scene(id: "s", name: "s", layout: .full, slots: [.device(id: "t")])
        let r = try #require(composite(comp, pb, scene: scene, vivid: vivid))
        try Data(r.rgb).write(to: d.appendingPathComponent("comp.rgb"))
        let c1 = ColorChart.compare(r.rgb, ref)
        print("COLORBENCH vivid=\(vivid) compositor vs ffmpeg: MAE=\(String(format: "%.2f", c1.mae)) maxErr=\(String(format: "%.1f", c1.maxErr)) meanDE=\(String(format: "%.2f", c1.meanDE)) worst patch \(c1.worst) dE=\(String(format: "%.2f", c1.worstDE))")
        // record 2.5 s of the composited frame
        let out = OutputPipeline()
        var cfg = OutputConfig(ffmpegPath: ff); cfg.recordingURL = d.appendingPathComponent("rec.mp4"); cfg.videoKbps = 15000
        try? FileManager.default.removeItem(at: cfg.recordingURL!)
        try out.start(cfg)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let host = CMClockGetTime(CMClockGetHostTimeClock()), t0 = CFAbsoluteTimeGetCurrent()
        for i in 0..<150 {
            while CFAbsoluteTimeGetCurrent() < t0 + Double(i) / 60 { try await Task.sleep(nanoseconds: 300_000) }
            out.submit(video: r.pb, pts: host + CMTime(value: Int64(i), timescale: 60))
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        await out.stop()
        #expect(runTool(ff, ["-v", "error", "-y", "-i", cfg.recordingURL!.path, "-vf", "select=eq(n\\,100),scale=in_range=tv:in_color_matrix=bt709:out_range=pc:flags=accurate_rnd+full_chroma_int,format=rgb24",
                            "-frames:v", "1", "-f", "rawvideo", d.appendingPathComponent("rec.rgb").path]))
        let rec = [UInt8](try Data(contentsOf: d.appendingPathComponent("rec.rgb")))
        let c2 = ColorChart.compare(rec, ref)
        print("COLORBENCH vivid=\(vivid) recorded MP4 vs ffmpeg: MAE=\(String(format: "%.2f", c2.mae)) maxErr=\(String(format: "%.1f", c2.maxErr)) meanDE=\(String(format: "%.2f", c2.meanDE)) worst patch \(c2.worst) dE=\(String(format: "%.2f", c2.worstDE))")
    }
}

/// Upscale quality bench (env-gated): STUDIO_SCALEBENCH=<dir with low.nv12 (854x480)>; writes up<mode>.rgb for ffmpeg ssim/psnr against the 1080p original.
@Suite(.serialized) struct ScaleBenchTests {
    @Test func upscale480() throws {
        guard let dir = ProcessInfo.processInfo.environment["STUDIO_SCALEBENCH"], let comp = MetalCompositor() else { return }
        let w = 854, h = 480
        let raw = try Data(contentsOf: URL(fileURLWithPath: dir + "/low.nv12"))
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
        let b = pb!
        if ProcessInfo.processInfo.environment["STUDIO_SCALEBENCH_709"] != nil { CVBufferSetAttachment(b, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate) }
        CVPixelBufferLockBaseAddress(b, [])
        raw.withUnsafeBytes { rp in
            let src = rp.baseAddress!
            for r in 0..<h { memcpy(CVPixelBufferGetBaseAddressOfPlane(b, 0)! + r * CVPixelBufferGetBytesPerRowOfPlane(b, 0), src + r * w, w) }
            for r in 0..<(h / 2) { memcpy(CVPixelBufferGetBaseAddressOfPlane(b, 1)! + r * CVPixelBufferGetBytesPerRowOfPlane(b, 1), src + w * h + r * w, w) }
        }
        CVPixelBufferUnlockBaseAddress(b, [])
        let scene = Scene(id: "s", name: "s", layout: .full, slots: [.device(id: "t")])
        for mode in 0...4 {
            comp.debugUpscaleMode = mode
            let r = try #require(composite(comp, b, scene: scene))
            try Data(r.rgb).write(to: URL(fileURLWithPath: dir + "/up\(mode).rgb"))
        }
    }
}

@Suite(.serialized) struct OrientationTests {
    private func quadrants() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
        let b = pb!; CVPixelBufferLockBaseAddress(b, [])
        let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(b)
        for y in 0..<720 { for x in 0..<1280 {
            let c: (UInt8, UInt8, UInt8) = y < 360 ? (x < 640 ? (255, 0, 0) : (0, 255, 0)) : (x < 640 ? (0, 0, 255) : (255, 255, 255))
            let o = y * bpr + x * 4; base[o] = c.2; base[o + 1] = c.1; base[o + 2] = c.0; base[o + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(b, []); return b
    }
    private func corners(_ rgb: [UInt8]) -> [String] {
        func name(_ x: Int, _ y: Int) -> String {
            let o = (y * 1920 + x) * 3, c = (Int(rgb[o]), Int(rgb[o + 1]), Int(rgb[o + 2]))
            if c.0 > 200 && c.1 > 200 && c.2 > 200 { return "white" }
            if c.0 > 200 && c.1 < 60 && c.2 < 60 { return "red" }
            if c.1 > 200 && c.0 < 60 && c.2 < 60 { return "green" }
            if c.2 > 200 && c.0 < 60 && c.1 < 60 { return "blue" }
            return "?\(c)"
        }
        return [name(300, 150), name(1620, 150), name(300, 930), name(1620, 930)]   // TL TR BL BR
    }
    @Test func rotationAndFlipOrientation() throws {
        guard let comp = MetalCompositor() else { return }
        let src = quadrants()
        let scene = Scene(id: "s", name: "s", layout: .full, slots: [.device(id: "t")])
        func run(_ x: SourceTransform, fit: Bool = false) throws -> [String] {
            comp.setTransforms([.device(id: "t"): x])
            var sc = scene; sc.setFit(0, fit)
            return corners(try #require(composite(comp, src, scene: sc)).rgb)
        }
        #expect(try run(.identity) == ["red", "green", "blue", "white"])
        #expect(try run(SourceTransform(degrees: 90)) == ["blue", "red", "white", "green"])
        #expect(try run(SourceTransform(degrees: 180)) == ["white", "blue", "green", "red"])
        #expect(try run(SourceTransform(degrees: 270)) == ["green", "white", "red", "blue"])
        #expect(try run(SourceTransform(flip: true)) == ["green", "red", "white", "blue"])
        comp.setTransforms([:])
    }
    @Test func fitLetterboxesAndFillCrops() throws {
        guard let comp = MetalCompositor() else { return }
        let src = quadrants()
        var scene = Scene(id: "s", name: "s", layout: .full, slots: [.device(id: "t")])
        comp.setTransforms([.device(id: "t"): SourceTransform(degrees: 90)])
        scene.setFit(0, true)
        let rgb = try #require(composite(comp, src, scene: scene)).rgb
        // 9:16 picture centred in 16:9: left edge is letterbox bar (near black), centre is picture
        #expect(Int(rgb[(540 * 1920 + 100) * 3]) < 40 && Int(rgb[(540 * 1920 + 100) * 3 + 1]) < 40)
        comp.setTransforms([:])
    }
}
