import Testing
import Foundation
import Metal
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Studio

private func allAdvancedScenes() -> [LayerScene] {
    let m = AdvancedStudioPreset.makeScenes()
    return JourneyStage.allCases.compactMap { m[$0] } + AdvancedStudioPreset.extraScenes()
}
/// Every key MatchKeys defines.
private func matchKeySet() -> Set<String> {
    var s: Set<String> = [MatchKeys.matchTitle, MatchKeys.map, MatchKeys.matchNumber, MatchKeys.round, MatchKeys.startsAt, MatchKeys.countdown,
                          MatchKeys.teamCount, MatchKeys.aliveTeams, MatchKeys.elapsed, MatchKeys.mvpName, MatchKeys.mvpTeam, MatchKeys.mvpKills,
                          MatchKeys.mvpDamage, MatchKeys.mvpPhoto, MatchKeys.winnerName, MatchKeys.winnerLogo, MatchKeys.winnerKills, MatchKeys.winnerTotal,
                          MatchKeys.preparing, MatchKeys.countdownGhost, MatchKeys.countdownLabel, MatchKeys.startsAtLocal, MatchKeys.matchLine]
    for n in 1...16 { s.formUnion([MatchKeys.rankName(n), MatchKeys.rankLogo(n), MatchKeys.rankKills(n), MatchKeys.rankPlacePts(n), MatchKeys.rankTotal(n)]) }
    for n in 1...4 { s.formUnion([MatchKeys.winnerPlayer(n), MatchKeys.winnerPlayerKills(n), MatchKeys.winnerPlayerDamage(n)]) }
    return s
}
private func writePNG(_ img: CGImage, _ path: String) {
    guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}
private func comp() -> MetalCompositor? { let c = MetalCompositor(); c?.layers.sprites.sync = true; return c }
private func render(_ c: MetalCompositor, _ s: LayerScene, t: Double, vars: SceneVariables = SceneVariables(MatchKeys.sample)) -> (CVPixelBuffer, Double) {
    var r = FrameRequest(); r.layerProgram = s; r.time = t; r.variables = vars
    r.programClock = AnimClock(sinceShow: t, sinceTake: t, time: t)
    let out = c.makeOutputBuffer()!
    let sem = DispatchSemaphore(value: 0)
    var ms = 0.0
    _ = c.render(r, to: FrameTargets(output: out)) { g in ms = g; sem.signal() }
    sem.wait()
    return (out, ms)
}
private func advPixel(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let q = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
    return (Int(q[2]), Int(q[1]), Int(q[0]))
}
private func advRenderSync(_ c: MetalCompositor, _ req: FrameRequest) -> CVPixelBuffer {
    let out = c.makeOutputBuffer()!
    let sem = DispatchSemaphore(value: 0)
    _ = c.render(req, to: FrameTargets(output: out)) { _ in sem.signal() }
    sem.wait()
    return out
}
private func digest(_ pb: CVPixelBuffer) -> Int {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let n = CVPixelBufferGetDataSize(pb)
    let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    var h = Hasher(); h.combine(bytes: UnsafeRawBufferPointer(start: p, count: n)); return h.finalize()
}
private func brightPixels(_ pb: CVPixelBuffer, threshold: Int = 120) -> Int {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    var n = 0
    for y in stride(from: 0, to: h, by: 4) { for x in stride(from: 0, to: w, by: 4) { let q = p + y * bpr + x * 4; if Int(q[0]) + Int(q[1]) + Int(q[2]) > threshold { n += 1 } } }
    return n
}

@Suite struct AdvancedSceneTests {
    @Test func presetHasEveryStageAndExtras() {
        let m = AdvancedStudioPreset.makeScenes()
        #expect(Set(m.keys) == Set(JourneyStage.allCases))
        let extra = AdvancedStudioPreset.extraScenes()
        #expect(extra.count == 2)                                            // BRB, Ending (the stinger is the pre-show stage)
        #expect(m[.preShow]?.id == "opus.adv.stinger")
        let ids = allAdvancedScenes().map(\.id)
        #expect(Set(ids).count == ids.count)
        for s in allAdvancedScenes() { #expect(s.canvas.w == 1920 && s.canvas.h == 1080); #expect(!s.layers.isEmpty) }
    }
    @Test func scenesRoundTripThroughJSON() throws {
        for s in allAdvancedScenes() {
            let data = try JSONEncoder().encode(s)
            let back = try JSONDecoder().decode(LayerScene.self, from: data)
            #expect(back == s, "\(s.name) changed through JSON")
        }
    }
    @Test func everyBindingIsAMatchKey() {
        let keys = matchKeySet()
        for s in allAdvancedScenes() {
            let used = Templates.placeholders(in: s)
            #expect(used.isSubset(of: keys), "\(s.name) uses unknown keys \(used.subtracting(keys))")
        }
        let sample = Set(MatchKeys.sample.keys)
        #expect(sample.isSubset(of: keys))
    }
    @Test func builtinAssetsResolve() {
        var missing: [String] = []
        for s in allAdvancedScenes() {
            s.forEachLayer { l in if case .image(let i) = l.kind, let b = i.builtin, BuiltinAssets.asset(b) == nil { missing.append(b) } }
        }
        #expect(missing.isEmpty, "missing assets \(missing)")
        for id in ["abg.logo.full", "abg.logo.mark", "abg.logo.wordmark"] {
            let a = BuiltinAssets.asset(id)
            #expect(a != nil)
            if let a { let img = a.image(); #expect(img.width > 300 && img.alphaInfo != .none) }
        }
    }
    @Test func oldScenesStillDecodeAndEncodeWithoutNewKeys() throws {
        let json = #"{"id":"x","name":"x","layers":[{"name":"e","kind":{"type":"effect","effect":{"kind":"embers","count":10}},"animations":[{"kind":"fade"}]}]}"#
        let s = try JSONDecoder().decode(LayerScene.self, from: Data(json.utf8))
        guard case .effect(let e) = s.layers[0].kind else { Issue.record("not an effect"); return }
        #expect(e.advanced == nil && e.delay == 0 && e.period == 0 && s.layers[0].shine == nil)
        let out = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(!out.contains("advanced") && !out.contains("shine") && !out.contains("\"period\""))
        // unknown future values decode leniently
        let j2 = #"{"kind":{"type":"effect","effect":{"kind":"sparks","advanced":"warpDrive"}},"shine":{"intensity":"x"}}"#
        let l = try JSONDecoder().decode(Layer.self, from: Data(j2.utf8))
        if case .effect(let e2) = l.kind { #expect(e2.advanced == nil && e2.kind == .sparks) }
        #expect(l.shine == Shine())
    }
    @Test func newAnimationKinds() {
        var l = Layer(kind: .shape(ShapeSpec()))
        l.animations = [Animation(trigger: .onShow, kind: .shake, duration: 0.5, delay: 1, from: 30, to: 0)]
        #expect(l.animState(AnimClock(sinceShow: 0.5)).dx == 0)                 // before the delay: still
        let mid = l.animState(AnimClock(sinceShow: 1.1))
        #expect(abs(mid.dx) + abs(mid.dy) > 0.5)
        #expect(l.animState(AnimClock(sinceShow: 1.1)) == mid)                   // deterministic
        #expect(l.animState(AnimClock(sinceShow: 3)).dx == 0)                   // settled
        l.animations = [AdvKit.drift(20, period: 10, dir: 0, scale: 0.02)]
        let a = l.animState(AnimClock(sinceShow: 2.5, time: 2.5))
        #expect(abs(a.dx) <= 20.01 && a.scale >= 1 && a.scale <= 1.0201)
        #expect(a != l.animState(AnimClock(sinceShow: 5, time: 5)))
    }
    @Test func shineAndOneShotTiming() {
        let s = Shine(duration: 1, period: 4, delay: 0.5)
        #expect(s.phase(sinceTake: 0.2) == nil)
        #expect(abs((s.phase(sinceTake: 1.0) ?? -1) - 0.5) < 1e-9)
        #expect(s.phase(sinceTake: 2.0) == nil)
        #expect(abs((s.phase(sinceTake: 4.75) ?? -1) - 0.25) < 1e-9)
        var spec = EffectSpec(.sparks); spec.advanced = .burst; spec.delay = 1
        #expect(AdvancedTiming.localTime(.burst, spec: spec, sinceTake: 0.5) == nil)
        #expect(AdvancedTiming.localTime(.burst, spec: spec, sinceTake: 1.5) == 0.5)
        #expect(AdvancedTiming.localTime(.burst, spec: spec, sinceTake: 9) == nil)          // finished: culled
        #expect(AdvancedTiming.localTime(.goldSmoke, spec: spec, sinceTake: 9) == 8)
    }
}

@Suite(.serialized) struct AdvancedEffectTests {
    private func one(_ fx: AdvancedFX, seed: UInt32 = 1, delay: Double = 0, blend: BlendMode = .add) -> LayerScene {
        let l = AdvKit.fx("fx", fx, color: ABG.gold1C, color2: ABG.redC, intensity: 1, speed: 1, count: fx == .hudDial ? 40 : 200, seed: seed, size: fx == .goldSmoke ? 300 : 30,
                          thickness: 3, angle: -30, delay: delay, x: 200, y: 100, w: 1400, h: 880, blend: fx == .confetti ? .normal : blend)
        return LayerScene(id: "fx-\(fx.rawValue)", name: fx.rawValue, background: .solid(.black), layers: [l])
    }
    @Test func everyEffectDrawsAndIsDeterministic() throws {
        guard let c = comp() else { return }
        for fx in AdvancedFX.allCases {
            let t = fx.isOneShot ? 0.45 : 2.3
            let a = render(c, one(fx), t: t).0, b = render(c, one(fx), t: t).0
            #expect(digest(a) == digest(b), "\(fx) not deterministic")
            #expect(brightPixels(a, threshold: fx == .hexGrid ? 24 : 120) > 20, "\(fx) drew nothing")
        }
    }
    @Test func seedsAndTimeChangeTheOutput() throws {
        guard let c = comp() else { return }
        for fx in [AdvancedFX.burst, .confetti, .energyStreaks, .glints, .bokeh] {
            let t = fx.isOneShot ? 0.5 : 2.0
            #expect(digest(render(c, one(fx, seed: 1), t: t).0) != digest(render(c, one(fx, seed: 2), t: t).0), "\(fx) ignores seed")
        }
        for fx in [AdvancedFX.shockwave, .lightWipe, .goldSmoke, .lensFlare] {
            #expect(digest(render(c, one(fx), t: 0.3).0) != digest(render(c, one(fx), t: 0.6).0), "\(fx) does not animate")
        }
    }
    @Test func oneShotsWaitForTheirDelayAndFinish() throws {
        guard let c = comp() else { return }
        for fx in [AdvancedFX.burst, .shockwave, .converge, .lightWipe] {
            #expect(brightPixels(render(c, one(fx, delay: 1), t: 0.5).0) == 0, "\(fx) fired early")
            #expect(brightPixels(render(c, one(fx, delay: 1), t: 1.4).0) > 20, "\(fx) did not fire")
            #expect(brightPixels(render(c, one(fx, delay: 1), t: 8).0) == 0, "\(fx) never ends")
        }
    }
    @Test func shineLightsOnlyTheArt() throws {
        guard let c = comp() else { return }
        var r = Layer.rect("r", x: 400, y: 300, w: 800, h: 400, fill: Fill(RGBA(0.4, 0.3, 0.1)))
        r.shine = Shine(intensity: 1.5, width: 0.1, angle: 0, duration: 1, period: 0, delay: 0)
        let s = LayerScene(id: "s", name: "s", background: .solid(.black), layers: [r])
        let pb = render(c, s, t: 0.5).0
        let mid = advPixel(pb, 800, 500), edge = advPixel(pb, 420, 500), outside = advPixel(pb, 300, 500)
        #expect(mid.r > edge.r + 40)          // band in the middle at phase 0.5
        #expect(outside.r < 10)               // nothing outside the layer
        let after = render(c, s, t: 3).0     // single sweep done -> plain colour again
        var plain = s; plain.layers[0].shine = nil
        #expect(abs(advPixel(after, 800, 500).r - advPixel(render(c, plain, t: 3).0, 800, 500).r) <= 1)
    }
    @Test func lightWipeTransitionMidpoint() throws {
        guard let c = comp() else { return }
        let a = LayerScene(id: "a", name: "a", background: .solid(RGBA(1, 0, 0)), layers: [])
        let b = LayerScene(id: "b", name: "b", background: .solid(RGBA(0, 0, 1)), layers: [])
        var r = FrameRequest(); r.layerProgram = b; r.layerPrevious = a; r.mix = 0.5; r.transition = SceneTransition(.lightWipe, duration: 1, direction: 180)
        let pb = advRenderSync(c, r)
        let right = advPixel(pb, 1900, 540), left = advPixel(pb, 20, 540)
        #expect(right.b > 150 && right.r < 80)       // new scene enters from the right
        #expect(left.r > 150 && left.b < 80)
    }
}

@Suite(.serialized) struct AdvancedBenchmarkTests {
    /// GPU time per frame of every scene at several animation times (sprites warm). Budget: < 6 ms on Apple silicon.
    @Test func everySceneFitsTheFrameBudget() throws {
        guard let c = comp() else { return }
        var report: [String] = []
        var worstAll = 0.0
        for s in allAdvancedScenes() {
            for t in [0.3, 1.2, 4.0] { _ = render(c, s, t: t) }             // warm sprites + pipelines
            var samples: [Double] = []
            for i in 0..<36 { samples.append(render(c, s, t: 0.2 + Double(i) * 0.12).1) }
            samples.sort()
            let p50 = samples[samples.count / 2], worst = samples.last!
            worstAll = max(worstAll, p50)
            report.append(String(format: "%@: p50 %.2f ms  max %.2f ms", s.name, p50, worst))
        }
        // single effects, full frame
        for fx in AdvancedFX.allCases {
            let l = AdvKit.fx("fx", fx, count: fx.particleKind != nil ? 300 : 40, size: fx == .goldSmoke ? 380 : 40, x: 0, y: 0, w: 1920, h: 1080)
            let s = LayerScene(id: "b-\(fx.rawValue)", name: fx.rawValue, background: .solid(.black), layers: [l])
            _ = render(c, s, t: 0.5)
            var smp: [Double] = []
            for i in 0..<12 { smp.append(render(c, s, t: 0.3 + Double(i) * 0.05).1) }
            smp.sort()
            report.append(String(format: "  fx %@ full-frame: p50 %.2f ms", fx.rawValue, smp[6]))
        }
        print("ADVANCED GPU BENCH\n" + report.joined(separator: "\n"))
        try? report.joined(separator: "\n").write(toFile: "/tmp/adv-shots/bench.txt", atomically: true, encoding: .utf8)
        #expect(worstAll < 6, "a scene needs \(worstAll) ms of GPU per frame")
    }
}

/// Dev: ADV_SHOTS=1 renders every scene with MatchKeys.sample at t = 0.3, 1, 2, 4 s (and empty values) into /tmp/adv-shots.
@Suite(.serialized) struct AdvancedShotsTests {
    @Test func renderShots() {
        guard ProcessInfo.processInfo.environment["ADV_SHOTS"] != nil else { return }
        try? FileManager.default.createDirectory(atPath: "/tmp/adv-shots", withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["ADV_ONLY"]
        let times = (ProcessInfo.processInfo.environment["ADV_TIMES"] ?? "0.3,1,2,4").split(separator: ",").compactMap { Double($0) }
        let size = ProcessInfo.processInfo.environment["ADV_FULL"] != nil ? CGSize(width: 1920, height: 1080) : CGSize(width: 1280, height: 720)
        let e = StudioEngine()
        let drop = ProcessInfo.processInfo.environment["ADV_DROP"]
        func prune(_ ls: [Layer]) -> [Layer] {
            ls.filter { l in drop.map { !l.name.contains($0) } ?? true }.map { l in var l = l; if case .group(let k) = l.kind { l.kind = .group(prune(k)) }; return l }
        }
        for s0 in allAdvancedScenes() where only == nil || s0.id.contains(only!) {
            var s = s0; s.layers = prune(s.layers)
            let slug = s.id.replacingOccurrences(of: "opus.adv.", with: "")
            for t in times {
                if let img = e.renderStill(s, size: size, variables: SceneVariables(MatchKeys.sample), time: t, clock: AnimClock(sinceShow: t, sinceTake: t, time: t)) {
                    writePNG(img, "/tmp/adv-shots/\(slug)-t\(t).png")
                }
            }
            if let img = e.renderStill(s, size: CGSize(width: 960, height: 540), variables: SceneVariables(), time: 4, clock: AnimClock(sinceShow: 4, sinceTake: 4, time: 4)) {
                writePNG(img, "/tmp/adv-shots/\(slug)-empty.png")
            }
        }
    }
}

private final class AdvNoSources: SourceProvider { func source(for ref: SourceRef) -> FrameSource? { nil } }

/// Dev: ADV_RECORD=1 records 12 s of startsIn -> gameplay -> summary -> winner (light-wipe transitions) through the real
/// StudioEngine + OutputPipeline into /tmp/adv-shots/journey.mp4.
@Suite(.serialized) struct AdvancedRecordTests {
    @Test func recordJourney() async throws {
        guard ProcessInfo.processInfo.environment["ADV_RECORD"] != nil else { return }
        guard let ff = FFmpegLocator.locate() else { Issue.record("no ffmpeg"); return }
        let url = URL(fileURLWithPath: "/tmp/adv-shots/journey.mp4")
        try? FileManager.default.removeItem(at: url)
        let out = OutputPipeline()
        var cfg = OutputConfig(ffmpegPath: ff); cfg.recordingURL = url
        try out.start(cfg)
        let engine = StudioEngine()
        let provider = AdvNoSources()
        engine.setSceneVariables(MatchKeys.sample)
        let m = AdvancedStudioPreset.makeScenes()
        #expect(engine.start(fps: 60, sink: out, provider: provider))
        let plan: [(JourneyStage, Double)] = [(.startsIn, 4), (.gameplay, 2), (.summary, 3), (.winner, 3)]
        for (i, (stage, secs)) in plan.enumerated() {
            engine.setProgram(m[stage], fade: i > 0)
            try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
        }
        let st = engine.stats
        print(String(format: "RECORD fps %.1f missed %d gpuAvg %.2f ms gpuP99 %.2f ms frameP99 %.2f ms", st.fps, st.missedDeadlines, st.gpuAvgMs, st.gpuP99Ms, st.frameP99Ms))
        engine.stop()
        await out.stop()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
