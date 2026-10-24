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
    private var program: LayerScene?, previewScene: LayerScene?, overlays = Overlays(), liveSince: Date?
    private var previous: LayerScene?, fadeStart: Double = 0, fadeLen: Double = 0
    private var transition = SceneTransition(.fade)
    private var programShownAt = 0.0, programTakeAt = 0.0, previousShownAt = 0.0, previewShownAt = 0.0
    private var variables = SceneVariables()
    private var stillComp: MetalCompositor?
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
        lock.withLock { stillComp = nil }
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

    /// Legacy fixed-layout scene: migrated to a LayerScene (same geometry) and shown through the layer renderer.
    func setProgram(_ scene: Scene?, fade: Bool = true) { setProgram(scene.map { LayerScene.migrate($0) }, fade: fade) }
    func setPreview(_ scene: Scene?) { setPreview(scene.map { LayerScene.migrate($0) }) }

    /// Put a layer scene on air. `transition` overrides the scene's own `transitionIn` and the default fade (`transitionMs`).
    func setProgram(_ scene: LayerScene?, fade: Bool = true, transition tr: SceneTransition? = nil) {
        let scene = scene.map(playableVideos)
        if let scene { warm(scene, wait: true) }
        let now = MachTime.seconds(ticks: MachTime.now)
        let fadeMsApplied: Double = lock.withLock {
            var t = tr ?? scene?.transitionIn ?? SceneTransition(.fade, duration: Double(_transitionMs) / 1000)
            if !fade || t.kind == .cut { t.duration = 0 }
            if t.duration > 0, program != nil, scene != nil {
                previous = program; previousShownAt = programShownAt; fadeStart = now; fadeLen = t.duration; transition = t
            } else { previous = nil; fadeLen = 0 }
            program = scene
            programShownAt = now; programTakeAt = now
            return t.duration > 0 && previous != nil ? t.duration * 1000 : 0
        }
        audio.setProgramSources(Set((scene?.sourceRefs ?? []).map(engineSourceKey)), fadeMs: fadeMsApplied)
    }
    /// The preview is applied once the scene's sprites (text, shapes, built-in art) are rasterised, so its first frame has no pop-in.
    func setPreview(_ scene: LayerScene?) {
        guard let scene = scene.map(playableVideos) else { lock.withLock { previewScene = nil; previewToken &+= 1 }; return }
        let token: Int = lock.withLock { previewToken &+= 1; return previewToken }
        let apply: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let now = MachTime.seconds(ticks: MachTime.now)
            self.lock.withLock {
                guard self.previewToken == token else { return }
                if self.previewScene?.id != scene.id { self.previewShownAt = now }
                self.previewScene = scene
            }
        }
        if isWarmed(scene) || comp == nil { apply() } else { warm(scene, wait: false, completion: apply) }
    }
    /// Live edit of a scene that is already on Program / Preview: swaps the content without restarting its animations.
    func replaceLive(_ scene: LayerScene) {
        let scene = playableVideos(scene)
        let onAir = lock.withLock { program?.id == scene.id }
        let inPreview = lock.withLock { previewScene?.id == scene.id }
        guard onAir || inPreview else { return }
        let apply: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let refs: Set<SourceRef>? = self.lock.withLock {
                var changed = false
                if self.program?.id == scene.id { changed = self.program?.sourceRefs != scene.sourceRefs; self.program = scene }
                if self.previewScene?.id == scene.id { self.previewScene = scene }
                return changed ? scene.sourceRefs : nil
            }
            if let refs, self.lock.withLock({ self.program?.id == scene.id }) { self.audio.setProgramSources(Set(refs.map(engineSourceKey)), fadeMs: 0) }
        }
        if isWarmed(scene) || comp == nil { apply() } else { warm(scene, wait: false, completion: apply) }
    }
    private var previewToken = 0
    private var warmed = Set<Int>()
    private let warmQueue = DispatchQueue(label: "engine.warm", qos: .userInitiated)
    private func isWarmed(_ s: LayerScene) -> Bool { lock.withLock { warmed.contains(s.hashValue) } }
    /// Rasterise a scene's sprites into the live compositor's shared sprite store (and load its images) ahead of time.
    func warm(_ scene: LayerScene, wait: Bool, completion: (@Sendable () -> Void)? = nil) {
        guard comp != nil, !isWarmed(scene) else { completion?(); return }
        let work: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let vars = self.sceneVariables
            let tiny = CGSize(width: 64, height: 36)
            _ = self.renderStill(scene, size: tiny, variables: vars)
            self.comp?.overlayImages.waitIdle(timeout: 2)
            _ = self.renderStill(scene, size: tiny, variables: vars)
            self.lock.withLock { if self.warmed.count > 300 { self.warmed.removeAll() }; self.warmed.insert(scene.hashValue) }
            completion?()
        }
        if wait { warmQueue.sync(execute: work) } else { warmQueue.async(execute: work) }
    }
    /// Live values for {{bindings}} (team1, score1, matchTitle, timer, viewers, ...). Merged over the previous set.
    func setSceneVariables(_ v: [String: String], replace: Bool = false) {
        lock.withLock { if replace { variables = SceneVariables(v) } else { for (k, x) in v { variables[k] = x } } }
    }
    func setSceneVariable(_ key: String, _ value: String) { lock.withLock { variables[key] = value } }
    var sceneVariables: SceneVariables { lock.withLock { variables } }
    /// A transient on-air animation (kill pop-up, flash, ...) drawn above the program scene for `duration` seconds; the layers animate from their own start.
    struct Trigger {
        var id: String
        var layers: [Layer]
        var duration: Double
        var hideLead = 0.45            // onHide animations start this long before the end
        var shake = 0.0                // screen-shake amplitude in output pixels
        var shakeDuration = 0.5
    }
    func fire(_ t: Trigger) {
        let now = MachTime.seconds(ticks: MachTime.now)
        lock.withLock {
            triggers.removeAll { $0.t.id == t.id }
            triggers.append((t, now))
        }
    }
    func clearTriggers() { lock.withLock { triggers.removeAll() } }
    private var triggers: [(t: Trigger, start: Double)] = []
    /// Replays "onTake" animations of the program scene.
    func retake() { let now = MachTime.seconds(ticks: MachTime.now); lock.withLock { programTakeAt = now } }
    /// Plays the program scene again from its first frame (show + take animations, one-shot effects), e.g. a looping stinger.
    func replayProgram() { let now = MachTime.seconds(ticks: MachTime.now); lock.withLock { programShownAt = now; programTakeAt = now } }

    /// Rasterise a scene to a CGImage (editor thumbnails, template gallery). Thread-safe, synchronous (blocks until the GPU finishes).
    func renderStill(_ scene: LayerScene, size: CGSize = CGSize(width: 480, height: 270), variables: SceneVariables = .sample, time: Double = 0, clock: AnimClock? = nil, provider: SourceProvider? = nil) -> CGImage? {
        let scene = playableVideos(scene)
        let c: MetalCompositor? = lock.withLock {
            if stillComp == nil { stillComp = MetalCompositor(sharedSprites: comp?.layers.sprites) }
            return stillComp
        }
        guard let c else { return nil }
        return stillLock.withLock {
            c.provider = provider ?? comp?.provider
            c.layers.introPropId = lock.withLock { _intro }
            if let live = comp { c.layers.overlayImages = live.overlayImages }
            c.overlayImages.propResolver = lock.withLock { propResolver }
            return c.renderStill(scene, size: size, variables: variables, time: time, clock: clock)
        }
    }
    private let stillLock = NSLock()
    /// Process-wide still renderer for UI code that has no engine instance.
    static let shared = StudioEngine()

    func setOverlays(_ o: Overlays) { lock.withLock { overlays = o } }
    /// Maps a prop id to its file (logo / web overlays that use props).
    /// A video prop placed as an *image* layer (the editor's picture path) can't be drawn as a still: play it as a video
    /// source instead, so it moves and its sound reaches the mix.
    func playableVideos(_ scene: LayerScene) -> LayerScene {
        let (r, dev) = lock.withLock { (propResolver, defaultDeviceId) }
        return scene.videoImagesAsSources { id in r?(id).map(isVideoFile) ?? false }.fillingEmptyDevices(with: dev)
    }
    private var defaultDeviceId: String?
    /// The phone used by source layers that don't name one (the live phone). Returns true when it changed.
    @discardableResult func setDefaultDevice(_ id: String?) -> Bool {
        lock.withLock { guard defaultDeviceId != id else { return false }; defaultDeviceId = id; return true }
    }
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

        struct Snap { var prog, prev, pv: LayerScene?; var ov: Overlays; var live: Date?; var mix: Float; var tr: SceneTransition
                      var pc, prc, pvc: AnimClock?; var vars: SceneVariables; var trig: [(layers: [Layer], clock: AnimClock)]; var shake: CGPoint }
        let timeNow = MachTime.seconds(ticks: t0 &- clk.originTicks)
        let snap: Snap = lock.withLock {
            var mix: Float = 1
            var prev = previous
            if prev != nil {
                let p = (nowS - fadeStart) / max(0.001, fadeLen)
                if p >= 1 { previous = nil; prev = nil } else { mix = Float(max(0, p)) }
            }
            comp.slateText = _slateText
            comp.layers.introPropId = _intro
            let pc = AnimClock(sinceShow: nowS - programShownAt, sinceTake: nowS - programTakeAt, sinceHide: nil, time: timeNow)
            let prc = prev == nil ? nil : AnimClock(sinceShow: nowS - previousShownAt, sinceTake: nowS - previousShownAt, sinceHide: nowS - fadeStart, time: timeNow)
            let pvc = AnimClock(sinceShow: nowS - previewShownAt, sinceTake: nowS - previewShownAt, sinceHide: nil, time: timeNow)
            triggers.removeAll { nowS - $0.start > $0.t.duration + 0.05 }
            var trig: [(layers: [Layer], clock: AnimClock)] = []
            var sx = 0.0, sy = 0.0
            for (t, start) in triggers {
                let age = nowS - start
                let hideAt = t.duration - t.hideLead
                trig.append((t.layers, AnimClock(sinceShow: age, sinceTake: age, sinceHide: age > hideAt ? age - hideAt : nil, time: timeNow)))
                if t.shake > 0, age < t.shakeDuration {
                    let k = pow(1 - age / t.shakeDuration, 2) * t.shake
                    let n = floor(age * 60)
                    func h(_ x: Double) -> Double { let v = sin(x * 12.9898 + t.shake) * 43758.5453; return v - floor(v) - 0.5 }
                    sx += h(n) * 2 * k; sy += h(n + 77) * 2 * k
                }
            }
            return Snap(prog: program, prev: prev, pv: previewScene, ov: overlays, live: liveSince, mix: mix, tr: transition, pc: pc, prc: prc, pvc: pvc, vars: variables, trig: trig, shake: CGPoint(x: sx, y: sy))
        }
        let (prog, prev, ov, live, pv, mix) = (snap.prog, snap.prev, snap.ov, snap.live, snap.pv, snap.mix)
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
        var req = FrameRequest(mix: mix, overlays: ov, liveSince: live, time: timeNow)
        req.layerProgram = prog; req.layerPrevious = prev; req.layerPreview = pv
        req.programClock = snap.pc; req.previousClock = snap.prc; req.previewClock = snap.pvc
        req.transition = snap.tr; req.variables = snap.vars; req.triggers = snap.trig; req.shake = snap.shake
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
