// Public face of the engine: scenes in, steady 1080p CFR frames + mixed audio out.
import Foundation
import CoreVideo
import CoreMedia
import CoreGraphics
import VideoToolbox

struct EngineStats {
    var fps = 0.0                 // actual render rate
    var frames = 0                // frames emitted
    var missedDeadlines = 0       // late wakes (> half a frame), GPU back-pressure holds, and skipped frames
    var heldFrames = 0            // ticks where the previous frame was re-sent (no free GPU slot / buffer)
    var frameP50Ms = 0.0, frameP99Ms = 0.0    // tick start -> GPU completion
    var gpuAvgMs = 0.0, gpuP99Ms = 0.0
    var encodeP99Ms = 0.0         // CPU time to encode a frame
}

final class StudioEngine {
    // configuration (set before or after start; thread-safe)
    var transitionMs: Int { get { lock.withLock { _transitionMs } } set { lock.withLock { _transitionMs = newValue } } }
    var slateText: String { get { lock.withLock { _slateText } } set { lock.withLock { _slateText = newValue } } }
    var introPropId: String? { get { lock.withLock { _intro } } set { lock.withLock { _intro = newValue } } }
    /// Monitors: IOSurface-backed BGRA CVPixelBuffers (480x270). Zero-copy into SwiftUI via layer.contents = CVPixelBufferGetIOSurface(pb).
    var onProgramPreview: ((CVPixelBuffer) -> Void)?
    var onPreviewPreview: ((CVPixelBuffer) -> Void)?
    /// Full-rate program feed: the composited output buffer itself (1920x1080 IOSurface, zero copy), once per emitted tick.
    var onProgramFrame: ((CVPixelBuffer) -> Void)?
    /// Same frame plus its nominal (jitter-free) CFR time in CACurrentMediaTime seconds: lets a display link pick the frame that
    /// belongs to a given vsync instead of whichever happened to complete last (removes beat judder between the 60 Hz clocks).
    var onProgramFrameTimed: ((CVPixelBuffer, Double, Int64) -> Void)?
    var previewFPS: Double = 30
    let audio = AudioMixer()
    /// Actual render rate (frames per second, 1 s window).
    var fps: Double { lock.withLock { _fps } }
    var stats: EngineStats {
        var s = lock.withLock { _stats }
        s.fps = fps
        s.frameP50Ms = frameWin.percentile(0.5); s.frameP99Ms = frameWin.percentile(0.99)
        s.gpuAvgMs = gpuWin.mean(); s.gpuP99Ms = gpuWin.percentile(0.99); s.encodeP99Ms = encWin.percentile(0.99)
        return s
    }
    /// "Vivid" final-pass enhancement (also drives the monitors). Applied immediately.
    var vivid: VividLevel { get { lock.withLock { _vivid } } set { lock.withLock { _vivid = newValue; comp?.vivid = newValue } } }
    /// Per-source rotation / flip.
    func setTransforms(_ t: [SourceRef: SourceTransform]) { lock.withLock { _transforms = t; comp?.setTransforms(t) } }
    private var _vivid = VividLevel.off, _transforms: [SourceRef: SourceTransform] = [:]
    private(set) var targetFPS = 60.0
    var isRunning: Bool { clock != nil }

    private let lock = NSLock()
    private var _transitionMs = 300, _slateText = "Starting soon", _intro: String?
    private var _fps = 0.0, _stats = EngineStats()
    private var program: Scene?, previewScene: Scene?, overlays = Overlays(), liveSince: Date?
    private var previous: Scene?, fadeStart: Double = 0, fadeLen: Double = 0
    private var comp: MetalCompositor?
    private var propResolver: (@Sendable (String) -> URL?)?
    private var clock: FrameClock?
    private weak var sink: VideoSink?
    private var lastOutput: CVPixelBuffer?
    private let frameWin = Window(), gpuWin = Window(), encWin = Window()
    private var fpsCount = 0, fpsStamp = 0.0
    private var tickCount: Int64 = 0

    init() {}

    @discardableResult
    func start(fps: Double = 60, sink: VideoSink, provider: SourceProvider) -> Bool {
        stop()
        guard let c = MetalCompositor() else { NSLog("StudioEngine: no Metal device"); return false }
        c.provider = provider
        lock.withLock { c.vivid = _vivid; c.setTransforms(_transforms) }
        c.overlayImages.propResolver = lock.withLock { propResolver }
        comp = c; self.sink = sink; targetFPS = fps; lastSubmittedPts = .invalid
        lock.withLock { _stats = EngineStats(); fpsCount = 0; fpsStamp = 0; tickCount = 0 }
        let clk = FrameClock(fps: fps)
        clock = clk
        clk.start { [weak self] t in self?.tick(t, clk) }
        audio.start(sink: sink, originTicks: clk.originTicks)
        return true
    }

    func stop() {
        clock?.stop(); clock = nil
        audio.stop()
        comp = nil; lastOutput = nil
    }

    // MARK: scene control

    func setProgram(_ scene: Scene?, fade: Bool = true) {
        let fadeMsApplied: Double = lock.withLock {
            let ms = fade ? _transitionMs : 0
            if ms > 0, program != nil, scene != nil { previous = program; fadeStart = MachTime.seconds(ticks: MachTime.now); fadeLen = Double(ms) / 1000 }
            else { previous = nil; fadeLen = 0 }
            program = scene
            return ms > 0 && previous != nil ? Double(ms) : 0
        }
        audio.setProgramSources(Set((scene?.slots ?? []).compactMap { $0 }.map(engineSourceKey)), fadeMs: fadeMsApplied)
    }
    func setPreview(_ scene: Scene?) { lock.withLock { previewScene = scene } }
    func setOverlays(_ o: Overlays) { lock.withLock { overlays = o } }
    /// Maps a prop id to its file (logo / web overlays that use props).
    func setPropResolver(_ r: (@Sendable (String) -> URL?)?) { lock.withLock { propResolver = r; comp?.overlayImages.propResolver = r } }
    /// Start/stop the LIVE bug clock.
    func setLiveClock(since: Date?) { lock.withLock { liveSince = since } }
    /// Preview -> program with the configured transition.
    func take() { if let p = lock.withLock({ previewScene }) { setProgram(p, fade: true) } }
    /// Preview -> program, hard cut.
    func cut() { if let p = lock.withLock({ previewScene }) { setProgram(p, fade: false) } }

    private var lastSubmittedPts = CMTime.invalid
    private let ptsLock = NSLock()
    /// The sink must see strictly increasing pts: a held frame (sent at once when the GPU is busy) can otherwise
    /// overtake an older frame whose GPU completion arrives later. A late older frame is dropped (the slot already shows the held frame).
    private func submitOrdered(_ sink: VideoSink, _ pb: CVPixelBuffer, _ pts: CMTime) {
        ptsLock.lock()
        if lastSubmittedPts.isValid, pts <= lastSubmittedPts { ptsLock.unlock(); return }
        lastSubmittedPts = pts
        ptsLock.unlock()
        sink.submit(video: pb, pts: pts)
    }

    // MARK: render tick (runs on the clock thread)

    private func tick(_ t: ClockTick, _ clk: FrameClock) {
        guard let comp = comp, let sink = sink else { return }
        let t0 = MachTime.now
        let late = t.lateSeconds
        var missed = t.skipped > 0 || late > clk.period * 0.5 ? 1 : 0
        let nowS = MachTime.seconds(ticks: t0)

        let (prog, prev, ov, live, pv, mix, tr): (Scene?, Scene?, Overlays, Date?, Scene?, Float, Void) = lock.withLock {
            var mix: Float = 1
            var prev = previous
            if prev != nil {
                let p = (nowS - fadeStart) / max(0.001, fadeLen)
                if p >= 1 { previous = nil; prev = nil } else { mix = Float(max(0, p)) }
            }
            let s = resolveSceneOpt(program, _intro), pvs = resolveSceneOpt(previewScene, _intro)
            comp.slateText = _slateText
            return (s, prev.map { resolveScene($0, introPropId: _intro) }, overlays, liveSince, pvs, mix, ())
        }
        _ = tr
        tickCount += 1
        let pEvery = max(1, Int((clk.fps / max(1, previewFPS)).rounded()))
        let doPreview = tickCount % Int64(pEvery) == 0 && (onProgramPreview != nil || onPreviewPreview != nil)

        let indices = (0..<t.due).map { t.firstIndex + Int64($0) }
        let hold: () -> Void = { [weak self] in
            guard let self = self, let last = self.lastOutput else { return }
            for i in indices { self.submitOrdered(sink, last, clk.pts(i)) }
            self.bump(held: 1)
        }
        guard let out = comp.makeOutputBuffer() else { missed += 1; hold(); finishTick(t, missed, indices.count); return }
        var targets = FrameTargets(output: out)
        if doPreview {
            if onProgramPreview != nil { targets.programPreview = comp.makePreviewBuffer() }
            if onPreviewPreview != nil, pv != nil { targets.scenePreview = comp.makePreviewBuffer() }
        }
        let req = FrameRequest(program: prog, previous: prev, mix: mix, overlays: ov, liveSince: live,
                               time: MachTime.seconds(ticks: t0 &- clk.originTicks), previewScene: pv)
        let enc0 = MachTime.now
        let ok = comp.render(req, to: targets) { [weak self] gpuMs in
            guard let self = self else { return }
            // Metal calls completions in submission order, so pts stay monotonic.
            for i in indices { self.submitOrdered(sink, out, clk.pts(i)) }
            self.lastOutput = out
            self.onProgramFrame?(out)
            if let cb = self.onProgramFrameTimed, let last = indices.last { cb(out, MachTime.seconds(ticks: clk.originTicks) + Double(last) / clk.fps, last) }
            self.gpuWin.add(gpuMs)
            self.frameWin.add(MachTime.seconds(ticks: MachTime.now &- t0) * 1000)
            if let p = targets.programPreview { self.onProgramPreview?(p) }
            if let p = targets.scenePreview { self.onPreviewPreview?(p) }
        }
        encWin.add(MachTime.seconds(ticks: MachTime.now &- enc0) * 1000)
        if !ok { missed += 1; hold() }
        finishTick(t, missed, indices.count)
    }

    private func resolveSceneOpt(_ s: Scene?, _ intro: String?) -> Scene? { s.map { resolveScene($0, introPropId: intro) } }

    private func bump(held: Int) { lock.withLock { _stats.heldFrames += held } }

    private func finishTick(_ t: ClockTick, _ missed: Int, _ emitted: Int) {
        let now = MachTime.seconds(ticks: MachTime.now)
        lock.withLock {
            _stats.frames += emitted
            _stats.missedDeadlines += missed + t.skipped
            if fpsStamp == 0 { fpsStamp = now }
            fpsCount += emitted
            if now - fpsStamp >= 1 { _fps = Double(fpsCount) / (now - fpsStamp); fpsCount = 0; fpsStamp = now }
        }
    }
}

extension CVPixelBuffer {
    /// Convenience for UI code that wants a CGImage of a (small) monitor frame.
    func studioCGImage() -> CGImage? {
        var img: CGImage?
        VTCreateCGImageFromCVPixelBuffer(self, options: nil, imageOut: &img)
        return img
    }
}
