import Foundation
import AVFoundation
import Darwin
import CoreVideo
import CoreMedia
import QuartzCore

/// Per-source health numbers for the UI / diagnostics.
struct SourceMetrics {
    var latency: TimeInterval = 0     // seconds behind the live edge
    var decodedFPS = 0.0
    var stalls = 0
    var rebuilds = 0
    var playing = false
    var decodeMsAvg = 0.0         // VideoToolbox submit -> output, per frame
    var decodeMsMax = 0.0
    var droppedFrames = 0         // access units skipped because decode fell behind (resumes at the next IDR)
    var width = 0, height = 0     // decoded picture size (what the phone really sends)
    var ingestKbps = 0.0          // incoming video bitrate measured on the stream copied out of MediaMTX
}

/// Phone video: a child ffmpeg reads the phone's RTMP stream from MediaMTX over loopback and remuxes it to raw Annex-B H.264
/// (`-c:v copy`, no transcode); we parse it, decode with VideoToolbox (hardware) and re-time the decoded frames through a tiny
/// jitter buffer so the engine's 60 Hz pull sees an even cadence. Latency is ~60-100 ms (smoothing delay + decode); the separate
/// PhoneAudioReader reads the same stream, so audio only needs `AudioSettings.phoneLatencyMs` (~ this latency) of compensation.
///
/// Pacing: each decoded frame gets a presentation time = clamp(previous + frame interval, arrival + minDelay, arrival + maxDelay),
/// where maxDelay widens with measured arrival jitter. Frames are therefore spaced evenly whenever the network allows it, and
/// latestFrame() (never blocks) returns the newest frame whose presentation time has passed.
/// B-frames: frames are timestamped in decode order; phone encoders in live mode emit none, so output order == decode order.
final class PhoneSource: FrameSource, @unchecked Sendable {
    let ref: SourceRef
    let input: String
    /// Unused (legacy HLS); kept so callers constructing with `hlsPort:` keep compiling.
    var audioHandler: ((CMSampleBuffer) -> Void)?

    /// Presentation-delay bounds (seconds): the floor covers decode-time jitter, the ceiling grows with network jitter up to `maxDelayCap`.
    static let minDelay = 0.050, baseMaxDelay = 0.080, maxDelayCap = 0.180

    private struct Slot { var pb: CVPixelBuffer; var due: Double; var arrival: Double }
    private let lock = NSLock()
    private var ring: [Slot] = []
    private var shown: CVPixelBuffer?
    private var m = SourceMetrics()
    private var stopped = false
    private var proc: Process?
    private let ffmpeg: String?
    private let extraInputArgs: [String]
    // pacing state (guarded by lock)
    private var interval = 1.0 / 60, lastArrival = 0.0, lastDue = 0.0, jitter = 0.0
    private var fpsCount = 0, fpsStart = CACurrentMediaTime(), lastFrameAt = 0.0, stallOpen = false, lastLatencyAt = 0.0
    private var dataAt = 0.0           // last time ffmpeg delivered bytes
    private var progressAt = 0.0       // last decoded frame (or process start): a connected-but-useless ffmpeg is restarted
    private var rateBytes = 0, rateStart = CACurrentMediaTime()
    private var runDecoded = 0         // frames decoded in the current ffmpeg run
    private(set) var ffmpegStarts = 0

    init(deviceId: String, hlsPort: Int = 8893, rtmpPort: Int = 1940, ffmpegPath: String? = FFmpegLocator.locate(), input: String? = nil, inputArgs: [String] = []) {
        ref = .device(id: deviceId)
        self.input = input ?? PhoneAudioReader.rtmpURL(deviceId: deviceId, port: rtmpPort)
        ffmpeg = ffmpegPath; extraInputArgs = inputArgs
        let t = Thread { [weak self] in self?.supervise() }
        t.name = "phone.video.reader"; t.qualityOfService = .userInteractive
        if ffmpegPath != nil { t.start() } else { NSLog("PhoneSource: ffmpeg not found; no phone video") }
    }

    var metrics: SourceMetrics {
        lock.lock(); defer { lock.unlock() }
        var out = m
        let now = CACurrentMediaTime()
        out.playing = lastFrameAt > 0 && now - lastFrameAt < 1.0
        if now - fpsStart >= 1.5 { out.decodedFPS = 0 }
        if !out.playing { out.ingestKbps = 0 }
        return out
    }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    // MARK: ffmpeg supervision

    private func supervise() {
        var backoff = 0.5
        while !isStopped {
            let began = CACurrentMediaTime()
            runOnce()
            if isStopped { break }
            // phone not publishing -> ffmpeg exits immediately: back off 0.5 s -> 5 s; a stream that ran a while retries quickly
            lock.lock(); let produced = runDecoded; lock.unlock()
            backoff = produced > 30 ? 0.3 : min(5, backoff * 2)
            lock.lock(); if ffmpegStarts > 1 || lastFrameAt > 0 { m.rebuilds += 1 }; lock.unlock()
            var slept = 0.0
            while slept < backoff, !isStopped { Thread.sleep(forTimeInterval: 0.05); slept += 0.05 }
        }
    }

    private func runOnce() {
        guard let ffmpeg else { return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-nostdin", "-v", ProcessInfo.processInfo.environment["STUDIO_DEBUG_PHONE"] == "verbose" ? "verbose" : "error", "-flags", "low_delay", "-probesize", "32768", "-analyzeduration", "0"] + extraInputArgs
            + ["-i", input, "-an", "-c:v", "copy", "-bsf:v", "h264_mp4toannexb", "-flush_packets", "1", "-f", "h264", "pipe:1"]
        let out = Pipe(); p.standardOutput = out
        p.standardError = ProcessInfo.processInfo.environment["STUDIO_DEBUG_PHONE"] != nil ? FileHandle.standardError : FileHandle.nullDevice
        lock.lock(); if stopped { lock.unlock(); return }; proc = p; ffmpegStarts += 1; dataAt = CACurrentMediaTime(); progressAt = dataAt; runDecoded = 0; lock.unlock()
        do { try p.run() } catch { NSLog("PhoneSource: ffmpeg launch failed: %@", "\(error)"); return }

        // watchdog: a connected-but-silent ffmpeg (phone hung) is killed so we reconnect
        let dog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        dog.schedule(deadline: .now() + 1, repeating: 1)
        dog.setEventHandler { [weak self, weak p] in
            guard let self, let p, p.isRunning else { return }
            self.lock.lock(); let now = CACurrentMediaTime(), idle = now - self.dataAt, noVideo = now - self.progressAt; self.lock.unlock()
            if idle > 5 || noVideo > 3 { p.terminate() }       // silent, or connected but no decodable video (bad join / hung phone)
        }
        dog.resume()

        let decoder = H264Decoder { [weak self] pb, arrival, dec in self?.decoded(pb, arrival: arrival, decode: dec) }
        var parser = AnnexBParser(), builder = AccessUnitBuilder()
        var needKey = true
        let dbgOn = ProcessInfo.processInfo.environment["STUDIO_DEBUG_PHONE"] != nil
        var dbgBytes = 0, dbgT = CACurrentMediaTime(), dbgBusy = 0.0
        func handle(_ au: AccessUnit) {
            if needKey && !au.isIDR { return }                                 // keyframe wait (start, after an error, or after dropping)
            // decode fell behind (VT backlog): drop everything until the next IDR instead of growing latency
            if decoder.inFlight > 6 && !au.isIDR { needKey = true; lock.lock(); m.droppedFrames += 1; lock.unlock(); return }
            needKey = !decoder.decode(au)
        }
        let fd = out.fileReadHandle()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 18)
        defer { buf.deallocate() }
        while true {
            let n = read(fd, buf, 1 << 18)
            if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
            let now = CACurrentMediaTime()
            lock.lock(); dataAt = now; rateBytes += n
            if now - rateStart >= 2 { let k = Double(rateBytes) * 8 / 1000 / (now - rateStart); m.ingestKbps = m.ingestKbps == 0 ? k : m.ingestKbps * 0.5 + k * 0.5; rateBytes = 0; rateStart = now }
            lock.unlock()
            if dbgOn { NSLog("PhoneSource read n=%ld t=%.3f", n, now); dbgBytes += n; if now - dbgT >= 2 { NSLog("PhoneSource rd: %.2f MB/s busy=%.0f%%", Double(dbgBytes) / (now - dbgT) / 1e6, dbgBusy / (now - dbgT) * 100); dbgBytes = 0; dbgBusy = 0; dbgT = now } }
            defer { if dbgOn { dbgBusy += CACurrentMediaTime() - now } }
            for nal in parser.feed(UnsafeBufferPointer(start: buf, count: n), at: now) {
                if let au = builder.add(nal) { handle(au) }
            }
            if isStopped { break }
        }
        dog.cancel()
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        decoder.invalidate()
        lock.lock(); interval = 1.0 / 60; lastArrival = 0; lastDue = 0; lock.unlock()
    }

    // MARK: decoded frames -> jitter buffer

    private func decoded(_ pb: CVPixelBuffer, arrival: Double, decode: Double) {
        let now = CACurrentMediaTime()
        lock.lock(); defer { lock.unlock() }
        if stopped { return }
        if lastArrival > 0 {
            let d = arrival - lastArrival
            if d > 0 && d < 0.25 {
                if d < interval * 3 { interval += (d - interval) * 0.02 }          // slow EMA of the true frame interval
                jitter += (abs(d - interval) - jitter) * 0.05
            }
        }
        lastArrival = arrival; progressAt = now; runDecoded += 1
        m.width = CVPixelBufferGetWidth(pb); m.height = CVPixelBufferGetHeight(pb)
        let maxDelay = min(Self.maxDelayCap, Self.baseMaxDelay + max(0, 4 * jitter - 0.02))
        var due = lastDue + interval
        due = min(max(due, arrival + Self.minDelay), arrival + maxDelay)
        if due <= lastDue { due = lastDue + 0.001 }
        lastDue = due
        ring.append(Slot(pb: pb, due: due, arrival: arrival))
        if ring.count > 16 { ring.removeFirst(ring.count - 16) }
        // metrics
        m.decodeMsAvg += (decode * 1000 - m.decodeMsAvg) * 0.05; m.decodeMsMax = max(m.decodeMsMax * 0.995, decode * 1000)
        fpsCount += 1
        if now - fpsStart >= 1 { m.decodedFPS = Double(fpsCount) / (now - fpsStart); fpsCount = 0; fpsStart = now }
        if lastFrameAt > 0, now - lastFrameAt > 0.5 { m.stalls += 1 }              // gap in decoded output
        lastFrameAt = now
    }

    func latestFrame() -> CVPixelBuffer? {
        let now = CACurrentMediaTime()
        lock.lock(); defer { lock.unlock() }
        var idx = -1
        for (i, s) in ring.enumerated() where s.due <= now { idx = i }
        if idx >= 0 {
            let s = ring[idx]
            ring.removeFirst(idx + 1)
            shown = s.pb
            let lat = now - s.arrival                                               // arrival -> screen (decode + smoothing)
            m.latency = m.latency == 0 ? lat : m.latency + (lat - m.latency) * 0.05
        }
        return shown
    }

    func stop() {
        lock.lock(); let was = stopped; stopped = true; let p = proc; ring = []; shown = nil; lock.unlock()
        guard !was else { return }
        if let p, p.isRunning { p.terminate() }
    }
    deinit { stop() }
}

private extension Pipe {
    func fileReadHandle() -> Int32 { fileHandleForReading.fileDescriptor }
}

/// Webcam through AVCaptureSession (NV12, IOSurface-backed).
final class CameraSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let ref: SourceRef = .camera
    private let session = AVCaptureSession()
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var count = 0, windowStart = CACurrentMediaTime(), fps = 0.0
    private let queue = DispatchQueue(label: "camera.source", qos: .userInteractive)

    var decodedFPS: Double { lock.lock(); defer { lock.unlock() }; return fps }

    override init() {
        super.init()
        AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in if ok { self?.queue.async { self?.configure() } } }
    }

    private func configure() {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        guard let dev = AVCaptureDevice.default(for: .video) ?? AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices.first,
              let input = try? AVCaptureDeviceInput(device: dev) else { return }
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        if session.canAddInput(input) { session.addInput(input) }
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                             kCVPixelBufferMetalCompatibilityKey as String: true]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let now = CACurrentMediaTime()
        lock.lock(); frame = pb; count += 1
        if now - windowStart >= 1 { fps = Double(count) / (now - windowStart); count = 0; windowStart = now }
        lock.unlock()
    }
    func latestFrame() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return frame }
    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } }; lock.lock(); frame = nil; lock.unlock() }
}

/// Resolves .device and .camera refs; other refs (slate, image, prop, web) belong to the Engine.
final class IngestSourceProvider: SourceProvider, @unchecked Sendable {
    private var sources: [SourceRef: FrameSource] = [:]
    private let lock = NSLock()
    let hlsPort: Int
    /// Resolves a prop id to its file + kind (set by IngestService; additive).
    var propResolver: ((String) -> (url: URL, kind: StoredProp.Kind)?)?
    var webCacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("7xen-web-cache")
    init(hlsPort: Int = 8893) { self.hlsPort = hlsPort }
    /// Phone audio -> mixer wiring (additive): `onPhoneCreated(key)` lets the mixer register "device:<id>" before audio flows;
    /// `phoneAudio(key, left, right)` receives 48 kHz PCM from a PhoneAudioReader (ffmpeg on the phone's stream: HLS exposes no
    /// audio track to AVFoundation, so the PhoneSource tap never fires). Set `ffmpegPath` + `rtmpPort` to enable it.
    var onPhoneCreated: ((String) -> Void)?
    var phoneAudio: ((String, [Float], [Float]) -> Void)?
    var ffmpegPath: String?
    var rtmpPort = 1940
    private var readers: [SourceRef: PhoneAudioReader] = [:]

    func source(for ref: SourceRef) -> FrameSource? {
        lock.lock(); defer { lock.unlock() }
        if let s = sources[ref], !((s as? PhoneSource)?.isStopped ?? false) { return s }
        let s: FrameSource
        switch ref {
        case .device(let id):
            let key = engineSourceKey(ref)
            onPhoneCreated?(key)
            s = PhoneSource(deviceId: id, hlsPort: hlsPort, rtmpPort: rtmpPort, ffmpegPath: ffmpegPath ?? FFmpegLocator.locate())
            readers[ref]?.stop(); readers[ref] = nil
            if let ff = ffmpegPath, phoneAudio != nil {
                let rd = PhoneAudioReader(input: PhoneAudioReader.rtmpURL(deviceId: id, port: rtmpPort), ffmpegPath: ff) { [weak self] l, r in self?.phoneAudio?(key, l, r) }
                readers[ref] = rd; rd.start()
            }
        case .camera: s = CameraSource()
        case .prop(let id):
            guard let p = propResolver?(id) else { return nil }
            s = p.kind == .video ? VideoFileSource(ref: ref, file: p.url) : ImageSource(ref: ref, file: p.url)
            if p.kind == .video { startFileAudio(ref, p.url) }
        case .image(let id):
            guard let p = propResolver?(id) else { return nil }
            s = p.kind == .image ? ImageSource(ref: ref, file: p.url) : VideoFileSource(ref: ref, file: p.url)
            if p.kind == .video { startFileAudio(ref, p.url) }
        case .web(let u):
            guard let url = URL(string: u), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            s = ImageSource(ref: ref, webURL: url, cacheDir: webCacheDir)
        default: return nil
        }
        sources[ref] = s; return s
    }
    func phone(_ id: String) -> PhoneSource? { source(for: .device(id: id)) as? PhoneSource }
    /// Restart video props from frame 0 (creates the source if it isn't running yet), and their audio with them.
    func restartVideos(_ refs: Set<SourceRef>) {
        for r in refs {
            switch r {
            case .prop, .image:
                guard let v = source(for: r) as? VideoFileSource else { continue }
                v.restart()
                lock.lock(); let f = fileAudio[r]; lock.unlock()
                if let f { startFileAudio(r, f) }
            default: break
            }
        }
    }
    private var fileAudio: [SourceRef: URL] = [:]
    /// A video prop's soundtrack, decoded in real time by ffmpeg (looping like the picture) into the mixer under
    /// engineSourceKey(ref), so it is heard while the prop's scene is on program. Caller may hold `lock`.
    private func startFileAudio(_ ref: SourceRef, _ url: URL) {
        guard let ff = ffmpegPath, phoneAudio != nil, !AVURLAsset(url: url).tracks(withMediaType: .audio).isEmpty else { return }
        let key = engineSourceKey(ref)
        onPhoneCreated?(key)
        let held = !lock.try()
        let old = readers.removeValue(forKey: ref); fileAudio[ref] = url
        let rd = PhoneAudioReader(input: url.path, inputArgs: ["-re", "-stream_loop", "-1"], ffmpegPath: ff) { [weak self] l, r in self?.phoneAudio?(key, l, r) }
        readers[ref] = rd
        if !held { lock.unlock() }
        old?.stop(); rd.start()
    }
    func metrics(deviceId: String) -> SourceMetrics? {
        lock.lock(); defer { lock.unlock() }
        return (sources[.device(id: deviceId)] as? PhoneSource)?.metrics
    }
    /// Stop and forget one source (e.g. a removed phone).
    func release(_ ref: SourceRef) { lock.lock(); let s = sources.removeValue(forKey: ref); let rd = readers.removeValue(forKey: ref); lock.unlock(); s?.stop(); rd?.stop() }
    func stopAll() { lock.lock(); let all = sources.values; sources = [:]; let rds = readers.values; readers = [:]; lock.unlock(); all.forEach { $0.stop() }; rds.forEach { $0.stop() } }
}
