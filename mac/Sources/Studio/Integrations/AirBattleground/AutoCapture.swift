// Auto capture: renders the CLEAN game feed (or a chosen scene) at 1080p off the main thread, encodes a JPEG (<= 2 MB) and sends it to the
// linked AirBattleground match: on a schedule (trigger=auto) and on demand ("Send screenshot", trigger=manual). The server classifies every
// frame (lobby / results / in-game); the studio never says what a screenshot shows (the optional hint is an operator training label).
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Observation

/// Renders a scene with the live sources at the current moment (thread-safe, called off the main thread).
typealias CaptureRenderer = @Sendable (LayerScene, CGSize) -> CGImage?

// MARK: - JPEG

struct CaptureFrame: @unchecked Sendable {
    var image: CGImage
    var jpeg: Data
    var quality: Double
    var thumbnail: CGImage?
    var width: Int { image.width }
    var height: Int { image.height }
}

enum CaptureEncoder {
    static let size = CGSize(width: 1920, height: 1080)
    static let quality = 0.85
    static let maxBytes = 2_000_000

    static func jpeg(_ img: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: max(0.05, min(1, quality))] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return out as Data
    }

    /// JPEG at `quality`, stepping the quality down until it fits `maxBytes`; as a last resort the picture is scaled down.
    static func capped(_ img: CGImage, quality: Double = quality, maxBytes: Int = maxBytes) -> (data: Data, quality: Double)? {
        var q = quality
        var image = img
        for _ in 0..<12 {
            guard let d = jpeg(image, quality: q) else { return nil }
            if d.count <= maxBytes { return (d, q) }
            if q > 0.3 { q = max(0.3, q - 0.15) }
            else if let smaller = scaled(image, width: image.width * 3 / 4) { image = smaller }
            else { return nil }
        }
        return nil
    }

    static func scaled(_ img: CGImage, width: Int) -> CGImage? {
        guard width > 0 else { return nil }
        let h = max(1, img.height * width / max(1, img.width))
        guard let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: h))
        return ctx.makeImage()
    }

    /// Render + encode + thumbnail. Runs on a background thread.
    static func make(_ scene: LayerScene, render: CaptureRenderer, size: CGSize = size, quality: Double = quality, maxBytes: Int = maxBytes) -> CaptureFrame? {
        guard let img = render(scene, size), let enc = capped(img, quality: quality, maxBytes: maxBytes) else { return nil }
        return CaptureFrame(image: img, jpeg: enc.data, quality: enc.quality, thumbnail: scaled(img, width: 320))
    }
}


// MARK: - What to capture: the clean feed (recommended) or a scene

/// A raw phone / camera feed the reader can capture without any of the studio's graphics.
struct CaptureFeed: Hashable, Sendable {
    var ref: SourceRef
    var name: String
    var online = true
    var label: String { "Clean feed: \(name) (recommended)" }
}

enum CaptureSource: Hashable, Sendable {
    /// the raw source full-frame (no Team Status board, no overlays)
    case feed(SourceRef)
    case scene(String)

    var tag: String {
        switch self {
        case .feed(.device(let id)): "feed:device:\(id)"
        case .feed(.camera): "feed:camera"
        case .feed(let r): "feed:other:\(String(describing: r))"
        case .scene(let id): "scene:\(id)"
        }
    }
    init?(tag: String) {
        if tag.hasPrefix("feed:device:") { self = .feed(.device(id: String(tag.dropFirst(12)))) }
        else if tag == "feed:camera" { self = .feed(.camera) }
        else if tag.hasPrefix("scene:") { self = .scene(String(tag.dropFirst(6))) }
        else { return nil }
    }
    var isFeed: Bool { if case .feed = self { true } else { false } }
}

enum CleanFeed {
    static let overlayWarning = "This scene has overlays the reader may misread — pick a clean feed"

    /// A temporary scene with only that source, full frame (fit .fill), on black.
    static func scene(_ f: CaptureFeed) -> LayerScene {
        LayerScene(id: "clean-feed:" + CaptureSource.feed(f.ref).tag.dropFirst(5), name: "Clean feed: \(f.name)", background: .solid(RGBA(hex: 0x000000)),
                   layers: [.source(f.name, f.ref, x: 0, y: 0, w: 1920, h: 1080, fit: .fill)])
    }
    /// true when the scene draws our own graphics the reader could read: a Team Status board or text layers (any depth, visible ones).
    static func hasOverlays(_ s: LayerScene) -> Bool {
        var found = false
        func walk(_ ls: [Layer]) {
            for l in ls where l.visible {
                switch l.kind {
                case .teamBoard, .text: found = true
                case .group(let c): walk(c)
                default: break
                }
            }
        }
        walk(s.layers)
        return found
    }
}

// MARK: - What to do after an answer (pure, tested)

enum CaptureFix: Equatable, Sendable { case connect, selectMatch }

struct CaptureDecision: Equatable, Sendable {
    /// seconds until the next capture (nil = stop)
    var delay: Double?
    /// the server picked the interval (nextIntervalSeconds)
    var serverInterval: Double?
    var sent = false
    var message: String?
    var fix: CaptureFix?
    var paused = false
    /// consecutive transient failures after this answer
    var failures = 0
    /// the server was still reading the previous frame (not an error)
    var busy = false
    var stops: Bool { delay == nil }
}

enum CapturePolicy {
    static let minInterval = 2.0, maxInterval = 60.0
    /// retry after a 409 (match locked / published)
    static let conflictRetry = 30.0
    static let backoff: [Double] = [5, 10, 30]
    static func clamp(_ s: Double) -> Double { min(maxInterval, max(minInterval, s)) }
    static func backoffDelay(failures: Int) -> Double { backoff[min(backoff.count - 1, max(0, failures - 1))] }

    static func decide(_ r: CaptureReply, interval: Double, failures: Int) -> CaptureDecision {
        switch r {
        case .accepted(_, _, let next):
            let s = next.map(clamp)
            return CaptureDecision(delay: s ?? interval, serverInterval: s, sent: true)
        case .duplicate(let next):
            let s = next.map(clamp)
            return CaptureDecision(delay: s ?? interval, serverInterval: s)
        case .busy(let next):   // carry on at the normal pace
            let s = next.map(clamp)
            return CaptureDecision(delay: s ?? interval, serverInterval: s, busy: true)
        case .badRequest(let m):
            return CaptureDecision(delay: nil, message: "AirBattleground: \(m)")
        case .keyRejected:
            return CaptureDecision(delay: nil, message: "AirBattleground didn't accept the studio key.", fix: .connect)
        case .matchNotFound(let m):
            return CaptureDecision(delay: nil, message: "Match not found on AirBattleground." + (m.map { " (\($0)) " } ?? " ") + "Pick the match again.", fix: .selectMatch)
        case .conflict(let m):
            return CaptureDecision(delay: conflictRetry, message: m ?? "AirBattleground isn't taking screenshots for this match right now.", paused: true)
        case .tooLarge:
            return CaptureDecision(delay: interval, message: "AirBattleground said the picture is too large, even at lower quality. Skipped.")
        case .rateLimited(let after):
            let w = max(1, after ?? conflictRetry)
            return CaptureDecision(delay: w, message: "AirBattleground asked the studio to slow down. Waiting \(Int(w.rounded())) s.")
        case .serverError(let code, let m):
            let n = failures + 1, d = backoffDelay(failures: n)
            return CaptureDecision(delay: d, message: "AirBattleground error (\(code)\(m.map { ": \($0)" } ?? "")). Frame skipped, retrying in \(Int(d)) s.", failures: n)
        case .unreachable:
            let n = failures + 1, d = backoffDelay(failures: n)
            return CaptureDecision(delay: d, message: "Can't reach AirBattleground. Frame skipped, retrying in \(Int(d)) s.", failures: n)
        }
    }

    /// What a MANUAL screenshot shows right after the upload (before the detection result).
    static func manualOutcome(_ r: CaptureReply) -> CaptureOutcome? {
        switch r {
        case .accepted: return nil   // -> poll the detection result
        case .duplicate: return CaptureOutcome(text: "Already sent (duplicate).", tone: .warn)
        case .busy: return CaptureOutcome(text: "AirBattleground is still reading the previous screenshot. Send again in a moment.", tone: .warn)
        case .conflict(let m): return CaptureOutcome(text: m ?? "AirBattleground isn't taking screenshots for this match right now.", tone: .error)
        default:
            return CaptureOutcome(text: decide(r, interval: 5, failures: 0).message ?? "Screenshot not sent.", tone: .error)
        }
    }
}

// MARK: - Settings (store.json, additive)

struct AutoCaptureSettings: Codable, Hashable, Sendable {
    /// legacy (two cards): read once to migrate the choice
    var liveSceneId: String? = nil
    var liveInterval: Double? = nil
    var resultsSceneId: String? = nil
    var resultsInterval: Double? = nil
    /// the one Auto capture: CaptureSource.tag (nil = default: the first clean feed)
    var source: String? = nil
    var interval: Double? = nil
    /// additive: Auto capture switched on before the match starts waits ("armed") and begins when the match goes live,
    /// and stops by itself when the match ends (nil = on)
    var startWithMatch: Bool? = nil
}

@MainActor protocol AutoCapturePersistence: AnyObject { var settings: AutoCaptureSettings { get set } }
@MainActor final class AutoCaptureMemoryPersistence: AutoCapturePersistence { var settings = AutoCaptureSettings() }
@MainActor final class AutoCaptureStorePersistence: AutoCapturePersistence {
    let store: StudioStore
    init(store: StudioStore) { self.store = store }
    var settings: AutoCaptureSettings {
        get { store.settings.autoCapture ?? AutoCaptureSettings() }
        set { store.update { $0.settings.autoCapture = newValue } }
    }
}

// MARK: - Session

/// What a session needs from the studio. Closures so tests can run without the app.
struct CaptureEnvironment {
    var isConnected: @MainActor () -> Bool
    var matchId: @MainActor () -> String?
    /// the scene on Program (fallback when no clean feed exists)
    var programSceneId: @MainActor () -> String?
    var scene: @MainActor (String) -> LayerScene?
    var render: CaptureRenderer
    var upload: @Sendable (CaptureUpload) async -> CaptureReply
    var now: @MainActor () -> Date = { Date() }
    /// clean phone / camera feeds (offered first)
    var feeds: @MainActor () -> [CaptureFeed] = { [] }
    /// GET …/captures/{captureId}
    var captureResult: @Sendable (_ matchId: String, _ captureId: String) async -> CaptureResultReply = { _, _ in .notFound }
    /// control.state of the picked match (nil = unknown / legacy)
    var controlState: @MainActor () -> MatchControl.State? = { nil }
    var sleep: @Sendable (Double) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000)) }
}

@MainActor @Observable
final class AutoCaptureSession {
    static let intervals: [Double] = [2, 3, 5, 10, 15]
    /// nil = the `kind` field is not sent (the server classifies). Kept for compatibility.
    let kind: CaptureKind?
    /// nil = default (the first clean feed, else the scene on Program)
    var source: CaptureSource? { didSet { if source != oldValue { onChange?() } } }
    /// the picked scene (compat with the scene card's "Auto capture this scene"); nil when a feed is picked
    var sceneId: String? {
        get { if case .scene(let id)? = source { id } else { nil } }
        set { source = newValue.map { .scene($0) } }
    }
    var interval: Double { didSet { if interval != oldValue { if !paused && failures == 0 { effectiveInterval = interval }; onChange?() } } }
    /// operator-picked label for the next manual screenshot (training only)
    var hint: CaptureHint?

    private(set) var running = false
    private(set) var inFlight = false
    private(set) var sentCount = 0
    private(set) var skipped = 0
    private(set) var busyCount = 0
    private(set) var lastSentAt: Date?
    private(set) var message: String?
    private(set) var fix: CaptureFix?
    private(set) var paused = false
    /// interval in use (the server may override it with nextIntervalSeconds)
    private(set) var effectiveInterval: Double
    private(set) var thumbnail: CGImage?
    private(set) var lastSize: Int?
    private(set) var sessionId = UUID().uuidString
    private(set) var sequence = 0
    /// the last answer was for a one-shot capture outside a running session
    private(set) var lastWasOneShot = false
    /// last manual "Send screenshot": its captureId, outcome (progress / ✓ / problem) and whether it is still polling
    private(set) var manualCaptureId: String?
    private(set) var manualOutcome: CaptureOutcome?
    private(set) var manualPolling = false
    private(set) var manualPending = false
    /// detected type of the last manual capture result (lobby / results / in_game / other)
    private(set) var lastDetected: String?

    @ObservationIgnored var env: CaptureEnvironment
    @ObservationIgnored var onChange: (() -> Void)?
    /// a manual capture finished (toast)
    @ObservationIgnored var onManualOutcome: ((CaptureOutcome) -> Void)?
    @ObservationIgnored private(set) var nextDueAt: Date?
    /// when the capture in flight was due: the next one is due exactly one interval later (fixed cadence, no drift)
    @ObservationIgnored private var lastDue: Date?
    @ObservationIgnored private(set) var failures = 0
    @ObservationIgnored private(set) var currentTask: Task<Void, Never>?
    @ObservationIgnored private(set) var pollTask: Task<Void, Never>?

    init(kind: CaptureKind? = nil, interval: Double, source: CaptureSource? = nil, env: CaptureEnvironment) {
        self.kind = kind; self.interval = interval; self.source = source; effectiveInterval = interval; self.env = env
    }
    convenience init(kind: CaptureKind? = nil, interval: Double, sceneId: String?, env: CaptureEnvironment) {
        self.init(kind: kind, interval: interval, source: sceneId.map { .scene($0) }, env: env)
    }

    // MARK: source

    private func valid(_ s: CaptureSource) -> Bool {
        switch s {
        case .feed(let r): env.feeds().contains { $0.ref == r }
        case .scene(let id): env.scene(id) != nil
        }
    }
    /// the picked source, or the default: first live clean feed, any clean feed, then the scene on Program
    var resolvedSource: CaptureSource? {
        if let s = source, valid(s) { return s }
        let feeds = env.feeds()
        if let f = feeds.first(where: \.online) ?? feeds.first { return .feed(f.ref) }
        return env.programSceneId().flatMap { env.scene($0) != nil ? .scene($0) : nil }
    }
    var resolvedSceneId: String? { if case .scene(let id)? = resolvedSource { id } else { nil } }
    /// what gets rendered for the resolved source
    var resolvedScene: LayerScene? {
        switch resolvedSource {
        case .feed(let r)?: env.feeds().first { $0.ref == r }.map(CleanFeed.scene)
        case .scene(let id)?: env.scene(id)
        case nil: nil
        }
    }
    var sceneName: String? { resolvedScene?.name }
    /// amber warning: the picked scene draws overlays (Team Status board, text) the reader may misread
    var overlayWarning: String? {
        guard case .scene? = resolvedSource, let s = resolvedScene, CleanFeed.hasOverlays(s) else { return nil }
        return CleanFeed.overlayWarning
    }

    /// Why capturing can't run right now (nil = ready).
    func blocker() -> (message: String, fix: CaptureFix?)? {
        if !env.isConnected() { return ("Connect AirBattleground to send screenshots to a match.", .connect) }
        if env.matchId() == nil { return ("Select the AirBattleground match these screenshots belong to.", .selectMatch) }
        if env.controlState() == .published { return ("This match is published. Screenshots are closed.", nil) }
        guard resolvedScene != nil else { return ("Pick a clean feed or a scene to capture.", nil) }
        return nil
    }

    @discardableResult
    func start(now: Date? = nil) -> Bool {
        if let b = blocker() { message = b.message; fix = b.fix; return false }
        // pin the source: Program / phones may change while capturing
        if source != resolvedSource { source = resolvedSource }
        running = true; paused = false; failures = 0; message = nil; fix = nil
        sessionId = UUID().uuidString; sequence = 0; sentCount = 0; skipped = 0; busyCount = 0
        effectiveInterval = interval
        // the first frame is sent one interval after starting (15 s picked = first send at +15 s), then every interval
        nextDueAt = (now ?? env.now()).addingTimeInterval(interval); lastDue = nil
        return true
    }
    func stop() { running = false; paused = false; nextDueAt = nil; failures = 0; if fix == nil { message = nil } }

    /// Called a few times a second while running: fires the capture that is due, or skips it while the previous upload is still in flight.
    func pump(now: Date) {
        guard running, let due = nextDueAt, now >= due else { return }
        lastDue = due
        nextDueAt = due.addingTimeInterval(effectiveInterval)   // provisional; the answer reschedules
        if inFlight { skipped += 1; return }
        currentTask = Task { await self.capture(manual: false) }
    }

    /// "Send screenshot": one capture now (trigger=manual), then its detection result is polled.
    /// While an auto frame is uploading, it runs right after it.
    func captureOnce() {
        if inFlight { manualPending = true; return }
        currentTask = Task { await self.capture(manual: true) }
    }

    func capture(manual: Bool) async {
        guard !inFlight else { if manual { manualPending = true } else { skipped += 1 }; return }
        if let b = blocker() {
            message = b.message; fix = b.fix
            if manual { manualOutcome = CaptureOutcome(text: b.message, tone: .error) }
            if running && (b.fix != nil) { running = false; nextDueAt = nil }
            return
        }
        guard let matchId = env.matchId(), let src = resolvedSource, let scene = resolvedScene else { return }
        inFlight = true
        if manual { manualOutcome = CaptureOutcome(text: "Sending…", tone: .progress); manualCaptureId = nil }
        if !running && sentCount == 0 && sequence == 0 { sessionId = UUID().uuidString }
        sequence += 1
        let seq = sequence, session = sessionId, at = env.now(), render = env.render
        let frame = await Task.detached(priority: .userInitiated) { CaptureEncoder.make(scene, render: render) }.value
        guard let frame else {
            inFlight = false
            message = "Couldn't render \"\(scene.name)\"."
            if manual { manualOutcome = CaptureOutcome(text: message!, tone: .error) }
            if running { nextDueAt = cadence(after: env.now()) }
            runPendingManual()
            return
        }
        thumbnail = frame.thumbnail
        let sceneId: String = { if case .scene(let id) = src { return id }; return scene.id }()
        var u = CaptureUpload(matchId: matchId, kind: kind, jpeg: frame.jpeg, captureId: UUID().uuidString, capturedAt: at, sequence: seq,
                              sessionId: session, sceneId: sceneId, sceneName: scene.name, width: frame.width, height: frame.height,
                              trigger: manual ? .manual : .auto, hint: manual ? hint : nil)
        lastSize = u.jpeg.count
        var reply = await env.upload(u)
        if reply == .tooLarge {   // once more, smaller
            let img = frame.image
            if let smaller = await Task.detached(priority: .userInitiated, operation: { CaptureEncoder.capped(img, quality: 0.6, maxBytes: CaptureEncoder.maxBytes / 2) }).value {
                u.jpeg = smaller.data; lastSize = u.jpeg.count
                reply = await env.upload(u)
            }
        }
        inFlight = false
        apply(reply, manual: manual)
        if manual { afterManualUpload(reply, matchId: matchId, captureId: u.captureId) }
        runPendingManual()
    }

    private func runPendingManual() {
        guard manualPending else { return }
        manualPending = false
        currentTask = Task { await self.capture(manual: true) }
    }

    func apply(_ reply: CaptureReply, manual: Bool = false) {
        let now = env.now()
        let d = CapturePolicy.decide(reply, interval: interval, failures: failures)
        failures = d.failures
        if d.sent { sentCount += 1; lastSentAt = now }
        if d.busy { busyCount += 1 }
        lastWasOneShot = manual && !running
        // a manual frame's own problem is shown on the Send screenshot line; a transient manual failure doesn't disturb the auto loop
        if !(manual && running && d.message != nil && !d.stops && !d.paused) { message = d.message; fix = d.fix }
        if d.stops {
            if running { running = false; nextDueAt = nil }
            paused = false
            return
        }
        guard running else { paused = false; return }
        if manual && d.failures > 0 { return }      // keep the auto schedule
        paused = d.paused
        // the operator's interval is the minimum: the server's nextIntervalSeconds may slow capture down, never speed it up
        if let s = d.serverInterval { effectiveInterval = max(interval, s) } else if d.message == nil { effectiveInterval = interval }
        if d.serverInterval == nil, d.message != nil || d.paused || failures > 0, let delay = d.delay {
            nextDueAt = now.addingTimeInterval(delay)                            // backoff / Retry-After / pause
        } else {
            nextDueAt = cadence(after: now)                                      // fixed cadence at the operator's interval
        }
    }
    /// Next due time on the fixed cadence: one interval after the previous due time (never in the past).
    private func cadence(after now: Date) -> Date {
        guard let d = lastDue else { return now.addingTimeInterval(effectiveInterval) }
        var next = d.addingTimeInterval(effectiveInterval)
        while next <= now { next = next.addingTimeInterval(effectiveInterval) }   // a slow upload skips to the next slot
        return next
    }

    private func afterManualUpload(_ reply: CaptureReply, matchId: String, captureId: String) {
        if let o = CapturePolicy.manualOutcome(reply) { finishManual(o); return }
        let id: String = { if case .accepted(let c?, _, _) = reply, !c.isEmpty { return c }; return captureId }()
        manualCaptureId = id
        manualOutcome = CaptureOutcome(text: "Sent. Waiting for the reader…", tone: .progress)
        pollTask?.cancel()
        pollTask = Task { await self.pollResult(matchId: matchId, captureId: id) }
    }

    /// Polls GET …/captures/{captureId} every 1.5 s for up to 60 s.
    func pollResult(matchId: String, captureId: String) async {
        manualPolling = true
        defer { if manualCaptureId == captureId { manualPolling = false } }
        var elapsed = 0.0
        while !Task.isCancelled {
            let reply = await env.captureResult(matchId, captureId)
            guard manualCaptureId == captureId else { return }       // a newer manual capture took over
            switch CaptureResultPolling.step(reply, elapsed: elapsed) {
            case .done(let r):
                lastDetected = r.detected
                finishManual(CaptureOutcome.from(r)); return
            case .timedOut: finishManual(.timedOut); return
            case .gone: finishManual(CaptureOutcome(text: "AirBattleground has no record of this screenshot. Send it again.", tone: .warn)); return
            case .wait:
                if case .result(let r) = reply { manualOutcome = CaptureOutcome.from(r) }
            }
            await env.sleep(CaptureResultPolling.interval)
            elapsed += CaptureResultPolling.interval
        }
    }
    private func finishManual(_ o: CaptureOutcome) {
        manualOutcome = o
        onManualOutcome?(o)
    }

    /// "Capturing every 5 s · last sent 14:05:12 · 37 sent" (or the problem)
    var statusLine: String {
        if let m = message { return m }
        let last = lastSentAt.map { " · last sent \(Self.clock.string(from: $0))" } ?? ""
        let n = sentCount > 0 ? " · \(sentCount) sent" : ""
        if running { return "Capturing every \(Self.secs(effectiveInterval))\(last)\(n)" + (inFlight && sentCount == 0 ? " · sending…" : "") }
        if inFlight { return "Sending…" }
        if lastWasOneShot, let t = lastSentAt { return "Sent at \(Self.clock.string(from: t))" }
        if sentCount > 0 { return "Stopped\(last)\(n)" }
        return lastSentAt.map { "Sent at \(Self.clock.string(from: $0))" } ?? "Not capturing"
    }
    var isError: Bool { message != nil && !paused }
    static func secs(_ s: Double) -> String { s == s.rounded() ? "\(Int(s)) s" : String(format: "%.1f s", s) }
    static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
}

// MARK: - Controller

@MainActor @Observable
final class AutoCaptureController {
    /// The ONE capture of the match (lobby, in-game and results all go to the same endpoint). Named `live` for older callers.
    let live: AutoCaptureSession
    var session: AutoCaptureSession { live }
    /// bumped to bring the Capture tab forward (scene card "Auto capture this scene")
    var focusRequest = 0
    /// transient toast for a manual screenshot's result
    private(set) var toast: CaptureOutcome?
    private(set) var toastSerial = 0
    var anyRunning: Bool { live.running }
    /// Auto capture is on but waiting for the match to start (start-with-match).
    private(set) var armed = false
    /// Start with the match / stop when it ends (default on).
    var startWithMatch: Bool { didSet { if startWithMatch != oldValue { save(); if !startWithMatch && armed { armed = false; live.start() } } } }
    /// on = capturing or armed (what the Auto capture switch shows)
    var autoOn: Bool { live.running || armed }
    @ObservationIgnored private var lastState: MatchControl.State?
    @ObservationIgnored private let persistence: AutoCapturePersistence
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored var toastSeconds: Double = 5

    init(env: CaptureEnvironment, persistence: AutoCapturePersistence? = nil, startLoop: Bool = true) {
        let p = persistence ?? AutoCaptureMemoryPersistence()
        self.persistence = p
        let s = p.settings
        let src = s.source.flatMap(CaptureSource.init(tag:)) ?? s.liveSceneId.map { .scene($0) }
        live = AutoCaptureSession(interval: s.interval ?? s.liveInterval ?? 5, source: src, env: env)
        startWithMatch = s.startWithMatch ?? true
        live.onChange = { [weak self] in self?.save() }
        live.onManualOutcome = { [weak self] o in self?.show(o) }
        if startLoop { startPumping() }
    }
    deinit { loop?.cancel() }

    private func save() {
        var s = persistence.settings
        s.source = live.source?.tag; s.interval = live.interval
        s.liveSceneId = live.sceneId; s.liveInterval = live.interval
        s.startWithMatch = startWithMatch
        persistence.settings = s
    }
    private func startPumping() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                self.followMatch()
                self.live.pump(now: Date())
            }
        }
    }
    func show(_ o: CaptureOutcome) {
        toast = o; toastSerial += 1
        let n = toastSerial, wait = toastSeconds
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if let self, self.toastSerial == n { self.toast = nil }
        }
    }
    func dismissToast() { toast = nil }
    /// Scene card: "Auto capture this scene" (restarts the capture on that scene).
    func autoCapture(sceneId: String) {
        if live.running { live.stop() }
        live.sceneId = sceneId
        live.start()
        focusRequest += 1
    }
    /// The Auto capture switch. With start-with-match on and a match that isn't live yet, it arms instead of starting.
    func setAuto(_ on: Bool) {
        guard on else { armed = false; live.stop(); return }
        let st = live.env.controlState()
        if startWithMatch, let st, st != .live {
            if let b = live.blocker() { _ = b; live.start(); return }    // shows why it can't run (connect / select match)
            armed = true
        } else {
            armed = false; live.start()
        }
    }
    /// Start-with-match: begin when the match goes live, stop when it ends (ended / published).
    func followMatch() {
        let st = live.env.controlState()
        defer { lastState = st }
        guard startWithMatch else { return }
        if armed, st == .live { armed = false; live.start() }
        if live.running, st == .ended || st == .published, lastState == .live || lastState == nil {
            live.stop()
        }
    }
    func sendScreenshot() { live.captureOnce() }
    func stopAll() { armed = false; live.stop() }
}
