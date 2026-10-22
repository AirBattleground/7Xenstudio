import Testing
import Metal
import Foundation
import CoreVideo
import CoreMedia
@testable import Studio

// MARK: helpers

func makeBGRA(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
    let bpr = CVPixelBufferGetBytesPerRow(pb!)
    for y in 0..<h { for x in 0..<w { let p = base + y * bpr + x * 4; p[0] = b; p[1] = g; p[2] = r; p[3] = 255 } }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}
func makeNV12(_ w: Int, _ h: Int, y: UInt8, cb: UInt8, cr: UInt8) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let yp = CVPixelBufferGetBaseAddressOfPlane(pb!, 0)!.assumingMemoryBound(to: UInt8.self)
    let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb!, 0)
    for r in 0..<h { for x in 0..<w { yp[r * ybpr + x] = y } }
    let cp = CVPixelBufferGetBaseAddressOfPlane(pb!, 1)!.assumingMemoryBound(to: UInt8.self)
    let cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb!, 1)
    for r in 0..<(h / 2) { for x in 0..<(w / 2) { cp[r * cbpr + 2 * x] = cb; cp[r * cbpr + 2 * x + 1] = cr } }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}
func pixel(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
    return (Int(p[2]), Int(p[1]), Int(p[0]))
}
func near(_ a: (r: Int, g: Int, b: Int), _ r: Int, _ g: Int, _ b: Int, tol: Int = 6) -> Bool {
    abs(a.r - r) <= tol && abs(a.g - g) <= tol && abs(a.b - b) <= tol
}

final class FakeSource: FrameSource {
    let ref: SourceRef
    var buffer: CVPixelBuffer?
    init(_ ref: SourceRef, _ b: CVPixelBuffer?) { self.ref = ref; buffer = b }
    func latestFrame() -> CVPixelBuffer? { buffer }
    func stop() {}
}
final class FakeProvider: SourceProvider {
    var sources: [SourceRef: FakeSource] = [:]
    func source(for ref: SourceRef) -> FrameSource? { sources[ref] }
}
final class CountingSink: VideoSink {
    private let lock = NSLock()
    var pts: [CMTime] = []; var audio = 0
    func submit(video: CVPixelBuffer, pts: CMTime) { lock.lock(); self.pts.append(pts); lock.unlock() }
    func submit(audio: CMSampleBuffer) { lock.lock(); audio_inc(); lock.unlock() }
    private func audio_inc() { audio += 1 }
    var snapshot: [CMTime] { lock.lock(); defer { lock.unlock() }; return pts }
}

func renderSync(_ c: MetalCompositor, _ req: FrameRequest) -> CVPixelBuffer {
    let out = c.makeOutputBuffer()!
    let sem = DispatchSemaphore(value: 0)
    #expect(c.render(req, to: FrameTargets(output: out)) { _ in sem.signal() })
    sem.wait()
    return out
}

// MARK: tests

@Suite struct LayoutTests {
    @Test func fullCoversCanvas() {
        let r = LayoutMath.rects(for: .full)
        #expect(r.count == 1 && r[0].rect == CGRect(x: 0, y: 0, width: 1920, height: 1080) && !r[0].framed)
    }
    @Test func sideIsSymmetricAndSixteenNine() {
        let r = LayoutMath.rects(for: .side)
        #expect(r.count == 2)
        #expect(abs(r[0].rect.width / r[0].rect.height - 16.0 / 9.0) < 0.001)
        #expect(abs(r[0].rect.minX - (1920 - r[1].rect.maxX)) < 0.001)
        #expect(abs(r[0].rect.midY - 540) < 0.001)
    }
    @Test func pipInsetBottomRight() {
        let r = LayoutMath.rects(for: .pip)
        #expect(r[1].rect == CGRect(x: (1280 - 384) * 1.5, y: (720 - 227) * 1.5, width: 540, height: 304.5))
    }
    @Test func deskAndTrioCounts() {
        #expect(LayoutMath.rects(for: .desk).count == 2)
        let t = LayoutMath.rects(for: .trio)
        #expect(t.count == 3 && t[1].rect.maxX <= 1920 && t[2].rect.maxY <= 1080)
        #expect(!t[0].rect.intersects(t[1].rect))
    }
    @Test func coverCropCentres() {
        let c = LayoutMath.coverCrop(srcW: 1000, srcH: 1000, dstW: 200, dstH: 100)
        #expect(c == CGRect(x: 0, y: 250, width: 1000, height: 500))
    }
}

@Suite(.serialized) struct RenderTests {
    @Test func fullLayoutShowsSourceColour() throws {
        guard let c = MetalCompositor() else { return }   // no GPU on this machine
        let prov = FakeProvider(); c.provider = prov
        prov.sources[.device(id: "a")] = FakeSource(.device(id: "a"), makeBGRA(1280, 720, r: 255, g: 0, b: 0))
        let scene = Scene(id: "1", name: "x", layout: .full, slots: [.device(id: "a")])
        let out = renderSync(c, FrameRequest(program: scene))
        #expect(near(pixel(out, 960, 540), 255, 0, 0))
        #expect(near(pixel(out, 5, 5), 255, 0, 0))
        #expect(near(pixel(out, 1914, 1074), 255, 0, 0))
    }
    @Test func downscaledAndColourManagedMidGrey() throws {
        guard let c = MetalCompositor() else { return }
        let prov = FakeProvider(); c.provider = prov
        prov.sources[.camera] = FakeSource(.camera, makeBGRA(3840, 2160, r: 30, g: 120, b: 200))
        let out = renderSync(c, FrameRequest(program: Scene(id: "1", name: "x", layout: .full, slots: [.camera])))
        #expect(near(pixel(out, 960, 540), 30, 120, 200, tol: 5))
    }
    @Test func nv12VideoRangeRed() throws {
        guard let c = MetalCompositor() else { return }
        let prov = FakeProvider(); c.provider = prov
        // BT.709 limited-range pure red: Y=63 Cb=102 Cr=240
        prov.sources[.device(id: "n")] = FakeSource(.device(id: "n"), makeNV12(1280, 720, y: 63, cb: 102, cr: 240))
        let out = renderSync(c, FrameRequest(program: Scene(id: "1", name: "x", layout: .full, slots: [.device(id: "n")])))
        #expect(near(pixel(out, 960, 540), 255, 0, 0, tol: 14))
        // limited-range white
        prov.sources[.device(id: "n")]!.buffer = makeNV12(1280, 720, y: 235, cb: 128, cr: 128)
        let w = renderSync(c, FrameRequest(program: Scene(id: "1", name: "x", layout: .full, slots: [.device(id: "n")])))
        #expect(near(pixel(w, 960, 540), 255, 255, 255, tol: 4))
    }
    @Test func sideLayoutBackgroundAndSlots() throws {
        guard let c = MetalCompositor() else { return }
        let prov = FakeProvider(); c.provider = prov
        prov.sources[.device(id: "l")] = FakeSource(.device(id: "l"), makeBGRA(640, 360, r: 0, g: 255, b: 0))
        prov.sources[.device(id: "r")] = FakeSource(.device(id: "r"), makeBGRA(640, 360, r: 0, g: 0, b: 255))
        let scene = Scene(id: "1", name: "x", layout: .side, slots: [.device(id: "l"), .device(id: "r")])
        let out = renderSync(c, FrameRequest(program: scene))
        let rects = LayoutMath.rects(for: .side)
        #expect(near(pixel(out, Int(rects[0].rect.midX), 540), 0, 255, 0))
        #expect(near(pixel(out, Int(rects[1].rect.midX), 540), 0, 0, 255))
        #expect(pixel(out, 960, 20).g < 40 && pixel(out, 960, 20).r < 40)  // dark gradient between/above slots
    }
    @Test func heldFrameWhenSourceStalls() throws {
        guard let c = MetalCompositor() else { return }
        let prov = FakeProvider(); c.provider = prov
        let src = FakeSource(.device(id: "a"), makeBGRA(640, 360, r: 0, g: 200, b: 0)); prov.sources[.device(id: "a")] = src
        let scene = Scene(id: "1", name: "x", layout: .full, slots: [.device(id: "a")])
        _ = renderSync(c, FrameRequest(program: scene))
        src.buffer = nil
        let out = renderSync(c, FrameRequest(program: scene))
        #expect(near(pixel(out, 960, 540), 0, 200, 0))
    }
    @Test func crossfadeMidpoint() throws {
        guard let c = MetalCompositor() else { return }
        let prov = FakeProvider(); c.provider = prov
        prov.sources[.device(id: "a")] = FakeSource(.device(id: "a"), makeBGRA(640, 360, r: 255, g: 0, b: 0))
        prov.sources[.device(id: "b")] = FakeSource(.device(id: "b"), makeBGRA(640, 360, r: 0, g: 0, b: 255))
        let a = Scene(id: "a", name: "a", layout: .full, slots: [.device(id: "a")])
        let b = Scene(id: "b", name: "b", layout: .full, slots: [.device(id: "b")])
        var req = FrameRequest(program: b); req.previous = a; req.mix = 0.0
        #expect(near(pixel(renderSync(c, req), 960, 540), 255, 0, 0))
        req.mix = 1.0 - 1e-6
        #expect(near(pixel(renderSync(c, req), 960, 540), 0, 0, 255, tol: 8))
        req.mix = 0.5
        let m = pixel(renderSync(c, req), 960, 540)
        #expect(m.r > 100 && m.b > 100 && m.g < 10)
    }
    @Test func slateAndOverlaysDrawSomething() throws {
        guard let c = MetalCompositor() else { return }
        let scene = Scene(id: "s", name: "s", layout: .full, slots: [.slate])
        let plain = renderSync(c, FrameRequest(program: scene))
        var ov = Overlays(); ov.ticker = true; ov.tickerText = "BREAKING NEWS"; ov.lowerThird = true; ov.lowerTitle = "Jane Doe"; ov.lowerSubtitle = "Host"; ov.liveBug = true
        let with = renderSync(c, FrameRequest(program: scene, overlays: ov, time: 1))
        // ticker "LIVE" tag is red at the bottom left; slate corner is dark teal-black
        #expect(near(pixel(with, 20, 1080 - 30), 229, 37, 42, tol: 20))
        #expect(!near(pixel(plain, 20, 1080 - 30), 229, 37, 42, tol: 40))
        #expect(near(pixel(with, 1920 - 200, 22 * 3 / 2 + 10), 229, 37, 42, tol: 20))   // live bug red box
        #expect(pixel(plain, 960, 540).g > 0)
    }
}

@Suite(.serialized) struct ClockTests {
    @Test func cadenceAndPts() throws {
        let clk = FrameClock(fps: 60)
        let lock = NSLock(); var idx: [Int64] = []; var maxLate = 0.0
        clk.start { t in lock.lock(); for i in 0..<t.due { idx.append(t.firstIndex + Int64(i)) }; maxLate = max(maxLate, t.lateSeconds); lock.unlock() }
        Thread.sleep(forTimeInterval: 1)
        clk.stop()
        lock.lock(); let got = idx; let late = maxLate; lock.unlock()
        #expect(got.count >= 56 && got.count <= 64)
        for (a, b) in zip(got, got.dropFirst()) { #expect(b == a + 1) }          // never skipped or duplicated
        #expect(clk.pts(60) == CMTime(value: 60000, timescale: 60000))
        #expect(late < 0.020)
    }
}

@Suite(.serialized) struct EngineTests {
    /// GPU cost of the upscale path + Vivid pass: three 854x480 phones in the trio (every tile upscaled), then a full-frame 480p. STUDIO_UPSCALE_MODE=0 / STUDIO_VIVID=0 reproduce the old path.
    @Test func upscaleBenchmark() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let prov = FakeProvider()
        let refs: [SourceRef] = (0..<3).map { .device(id: "p\($0)") }
        for r in refs { prov.sources[r] = FakeSource(r, makeNV12(854, 480, y: 100, cb: 120, cr: 140)) }
        let sink = CountingSink(); let eng = StudioEngine()
        eng.vivid = VividLevel(rawValue: Int(ProcessInfo.processInfo.environment["STUDIO_VIVID"] ?? "") ?? 1) ?? .subtle
        #expect(eng.start(fps: 60, sink: sink, provider: prov))
        eng.setProgram(Scene(id: "t", name: "trio", layout: .trio, slots: refs), fade: false)
        Thread.sleep(forTimeInterval: 2)
        eng.setProgram(Scene(id: "f", name: "full", layout: .full, slots: [refs[0]]), fade: false)
        Thread.sleep(forTimeInterval: 2)
        eng.stop(); let s = eng.stats
        print(String(format: "ENGINE BENCH480 fps=%.2f missed=%d held=%d frame p50=%.2fms p99=%.2fms gpu avg=%.2fms p99=%.2fms", s.fps, s.missedDeadlines, s.heldFrames, s.frameP50Ms, s.frameP99Ms, s.gpuAvgMs, s.gpuP99Ms))
    }

    @Test func endToEndCFRAndBenchmark() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let prov = FakeProvider()
        let refs: [SourceRef] = (0..<4).map { .device(id: "p\($0)") }
        for (i, r) in refs.enumerated() {
            prov.sources[r] = FakeSource(r, i % 2 == 0 ? makeNV12(1920, 1080, y: 100, cb: 120, cr: 140) : makeBGRA(1280, 720, r: 40, g: 90, b: UInt8(60 + i * 30)))
        }
        let sink = CountingSink()
        let eng = StudioEngine()
        var prevFrames = 0
        eng.onProgramPreview = { _ in prevFrames += 1 }
        #expect(eng.start(fps: 60, sink: sink, provider: prov))
        eng.setProgram(Scene(id: "t", name: "trio+", layout: .trio, slots: Array(refs.prefix(3))), fade: false)
        eng.setOverlays({ var o = Overlays(); o.ticker = true; o.tickerText = "benchmark ticker"; o.liveBug = true; return o }())
        Thread.sleep(forTimeInterval: 1)
        eng.setProgram(Scene(id: "q", name: "side", layout: .side, slots: [refs[0], refs[3]]))   // fade
        Thread.sleep(forTimeInterval: 3)
        eng.stop()
        let s = eng.stats
        let pts = sink.snapshot
        print(String(format: "ENGINE BENCH fps=%.2f frames=%d missed=%d held=%d frame p50=%.2fms p99=%.2fms gpu avg=%.2fms p99=%.2fms encode p99=%.2fms previews=%d",
                     s.fps, s.frames, s.missedDeadlines, s.heldFrames, s.frameP50Ms, s.frameP99Ms, s.gpuAvgMs, s.gpuP99Ms, s.encodeP99Ms, prevFrames))
        #expect(pts.count >= 230 && pts.count <= 250)
        for (a, b) in zip(pts, pts.dropFirst()) { #expect(b > a) }
        #expect(abs(s.fps - 60) < 3)
    }
}

@Suite(.serialized) struct OverlayImageTests {
    func writePNG(_ url: URL, w: Int, h: Int, r: UInt8, g: UInt8, b: UInt8) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
    }
    func render(_ c: MetalCompositor, _ req: FrameRequest) -> CVPixelBuffer {
        _ = renderSync(c, req); c.overlayImages.waitIdle()
        return renderSync(c, req)
    }

    @Test func oldOverlaysDecode() throws {
        let old = #"{"liveBug":true,"lowerThird":false,"ticker":true,"lowerTitle":"A","lowerSubtitle":"B","tickerText":"T"}"#
        let o = try JSONDecoder().decode(Overlays.self, from: Data(old.utf8))
        #expect(o.liveBug && o.ticker && o.lowerTitle == "A" && o.logo == LogoOverlay() && o.web == WebOverlay())
        var n = Overlays(); n.logo.on = true; n.logo.corner = .bl; n.web.url = "x"; n.web.w = 0.5
        #expect(try JSONDecoder().decode(Overlays.self, from: JSONEncoder().encode(n)) == n)
    }

    @Test func logoAndWebRender() throws {
        guard let c = MetalCompositor() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ovimg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logo = dir.appendingPathComponent("logo.png"), web = dir.appendingPathComponent("web.png")
        writePNG(logo, w: 180, h: 100, r: 255, g: 0, b: 0)
        writePNG(web, w: 100, h: 100, r: 0, g: 0, b: 255)
        c.overlayImages.propResolver = { $0 == "logo" ? logo : nil }
        let scene = Scene(id: "s", name: "s", layout: .full, slots: [.slate])
        var ov = Overlays()
        ov.logo.on = true; ov.logo.propId = "logo"; ov.logo.corner = .tl
        let on = render(c, FrameRequest(program: scene, overlays: ov))
        // logo box starts at 28 design units (42 px) from the top-left
        #expect(near(pixel(on, 42 + 40, 42 + 30), 255, 0, 0, tol: 10))
        #expect(!near(pixel(on, 1700, 900), 255, 0, 0, tol: 40))
        ov.logo.opacity = 0.5
        let half = render(c, FrameRequest(program: scene, overlays: ov))
        #expect(pixel(half, 42 + 40, 42 + 30).r < 230 && pixel(half, 42 + 40, 42 + 30).r > 60)

        ov.logo.on = false
        ov.web.on = true; ov.web.url = web.absoluteString; ov.web.x = 0.5; ov.web.y = 0.5; ov.web.w = 0.5; ov.web.h = 0.5
        let w = render(c, FrameRequest(program: scene, overlays: ov))
        // fitted square centred in the bottom-right quadrant (540x540 px at x 1230..., y 540...)
        #expect(near(pixel(w, 1440, 810), 0, 0, 255, tol: 12))
        #expect(!near(pixel(w, 200, 200), 0, 0, 255, tol: 40))
    }
}
