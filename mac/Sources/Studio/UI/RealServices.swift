import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import AVFoundation

private final class MediaCache: @unchecked Sendable {
    let lock = NSLock()
    var thumbs: [String: CGImage] = [:], thumbPending: Set<String> = []
    var durations: [String: (size: Int64, secs: TimeInterval)] = [:], durationPending: Set<String> = []
    func store(duration d: Double, key: String, size: Int64) {
        lock.lock(); defer { lock.unlock() }
        durations[key] = (size, d.isFinite && d > 0 ? d : 0)
        durationPending.remove(key)
    }
    func drop(_ id: String) { lock.lock(); thumbs[id] = nil; lock.unlock() }
    func store(thumb: CGImage?, id: String) {
        lock.lock(); defer { lock.unlock() }
        if let thumb { thumbs[id] = thumb }
        thumbPending.remove(id)
    }
}

final class FrameBox: @unchecked Sendable {
    private let lock = NSLock(); private var pb: CVPixelBuffer?; private var n: UInt64 = 0
    /// Last few frames with their nominal CFR time / index (newest last) for display-link pacing.
    private var ring: [(pb: CVPixelBuffer, t: Double, idx: Int64)] = []
    nonisolated(unsafe) static var dbgHook: ((Double, Double, Double) -> Void)?
    func set(_ p: CVPixelBuffer) { lock.lock(); pb = p; n &+= 1; lock.unlock() }
    func setTimed(_ p: CVPixelBuffer, _ t: Double, _ idx: Int64) {
        lock.lock(); pb = p; n &+= 1
        ring.append((p, t, idx)); if ring.count > 8 { ring.removeFirst() }
        lock.unlock()
    }
    var serial: UInt64 { lock.lock(); defer { lock.unlock() }; return n }
    func get() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return pb }
    /// Display-link pacing. `desired` = the (fractional) frame index that is `delay` old at the vsync `target`. The cursor advances
    /// exactly one frame per vsync and only re-syncs (skip ahead / hold one tick) when it is more than a frame away from `desired`,
    /// so engine and display clocks that are equal (or drift slowly) give a perfectly regular cadence instead of the flip-flopping a
    /// "newest frame older than X" rule shows when the phase sits near X.
    func paced(target: Double, delay: Double, fps: Double, cursor: inout Int64?) -> (CVPixelBuffer, Int64)? {
        lock.lock(); defer { lock.unlock() }
        guard let ref = ring.last else { return nil }
        let desired = Double(ref.idx) + (target - delay - ref.t) * fps
        if let c = cursor {
            let err = desired - Double(c + 1)
            if err > 1.0 { cursor = Int64(desired.rounded(.down)) }
            else if err >= -1.0 { cursor = c + 1 }          // else: ahead by more than a frame, hold this one
        } else { cursor = Int64(desired.rounded(.down)) }
        let c = cursor!
        let pick = ring.last(where: { $0.idx <= c }) ?? ring.first!
        Self.dbgHook?(target, pick.t, ref.t)
        return (pick.pb, pick.idx)
    }
}

/// Wires Core store + Ingest (HTTP, MediaMTX, phone sources) + StudioEngine + OutputPipeline behind `StudioServices`.
@MainActor
final class RealServices: StudioServices {
    let ingest: IngestService
    let engine = StudioEngine()
    let output = OutputPipeline()
    private static let logStats = ProcessInfo.processInfo.environment["STUDIO_MONITOR_LOG"] != nil
    private var lastStatLog = Date.distantPast
    private let programBox = FrameBox(), previewBox = FrameBox()
    private var statuses: [DeviceStatus] = []
    private var pollTask: Task<Void, Never>?
    private(set) var programSceneID: String?
    private(set) var previewSceneID: String?
    private var live = false, liveSince: Date?, recordingFile: String?, activeDests: [Destination] = []
    private var lastError: String?
    private var showId = ""
    private(set) var audio: AudioController?
    private let cache = MediaCache()
    private var recordHEVC = false
    var slateText: String {
        get { store.settings.slateText ?? "Starting soon" }
        set { store.setSlateText(newValue); engine.slateText = newValue }
    }
    var introPropId: String? {
        get { store.settings.introPropId }
        set { store.setIntroProp(newValue); engine.introPropId = newValue }
    }
    var transitionMs: Int { get { engine.transitionMs } set { engine.transitionMs = newValue } }
    var overlays = Overlays() { didSet { engine.setOverlays(overlays); if !showId.isEmpty { store.saveOverlays(overlays, forShow: showId) } } }

    var store: StudioStore { ingest.store }
    var studioName: String { store.studioName }
    var lanURL: String { ingest.lanURL }

    init(ingest: IngestService) {
        self.ingest = ingest
        if store.scenes.isEmpty { for s in defaultScenes(firstDeviceId: store.devices.first?.id) { store.upsert(s) } }
        let show = ingest.store.ensureActiveShow()
        showId = show.id; overlays = show.overlays; engine.setOverlays(show.overlays)
        let st = ingest.store
        engine.setPropResolver { st.propURL($0) }
        OverlayPropCatalog.imageProps = { st.props.filter { $0.kind == .image }.map { ($0.id, $0.name) } }
        engine.onProgramFrameTimed = { [programBox] pb, t, i in programBox.setTimed(pb, t, i) }
        engine.onPreviewPreview = { [previewBox] in previewBox.set($0) }
        engine.slateText = slateText; engine.introPropId = introPropId
        let ac = AudioController(mixer: engine.audio, store: ingest.store)
        audio = ac
        let mx = engine.audio
        ingest.sourceProvider.onPhoneCreated = { key in mx.addSource(id: key, followsProgram: true, jitterMs: 150) }
        ingest.sourceProvider.phoneAudio = { key, l, r in mx.push(id: key, left: l, right: r) }
        ingest.start()
        if !engine.start(fps: Double(defaultFPS), sink: output, provider: ingest.sourceProvider) { lastError = "Could not start the Metal compositor" }
        let sc = store.scenes
        if let first = sc.first { programSceneID = first.id; engine.setProgram(first, fade: false) }
        if let second = sc.dropFirst().first ?? sc.first { previewSceneID = second.id; engine.setPreview(second) }
        let dm = ingest.devices
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let s = await dm.statuses()
                self?.statuses = s
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func setStudioName(_ n: String) async throws {
        let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...40).contains(t.count) else { throw ServiceError(message: "Studio name needs 2 to 40 characters") }
        store.setStudioName(t)
    }

    func devices() -> [DeviceInfo] {
        statuses.map { DeviceInfo(id: $0.id, name: $0.name, online: $0.online, streaming: $0.streaming, videoReady: $0.videoReady,
                                  battery: $0.battery.map { Int(($0 * 100).rounded()) }, model: $0.model) }
    }
    func createDevice(name: String) async throws -> PairingInfo {
        do {
            let r = try ingest.devices.create(name: name)
            statuses = await ingest.devices.statuses()
            return PairingInfo(device: DeviceInfo(id: r.device.id, name: r.device.name), pairURL: r.pairURL, key: r.key)
        } catch let e as APIError { throw ServiceError(message: e.message) }
    }
    func deleteDevice(id: String) async {
        try? await ingest.devices.remove(id)
        statuses.removeAll { $0.id == id }
    }

    func scenes() -> [Scene] { store.scenes }
    func saveScene(_ s: Scene) async {
        store.upsert(s)
        if s.id == programSceneID { engine.setProgram(s, fade: false) }
        if s.id == previewSceneID { engine.setPreview(s) }
    }
    func deleteScene(id: String) async {
        store.removeScene(id)
        if previewSceneID == id { previewSceneID = store.scenes.first?.id; engine.setPreview(store.scenes.first) }
        if programSceneID == id { programSceneID = store.scenes.first?.id; engine.setProgram(store.scenes.first, fade: false) }
    }
    func setPreview(sceneID: String) {
        guard let s = store.scenes.first(where: { $0.id == sceneID }) else { return }
        previewSceneID = sceneID; engine.setPreview(s)
    }
    func take(_ t: TransitionKind) {
        guard let id = previewSceneID else { return }
        if t == .cut { engine.cut() } else { engine.take() }
        programSceneID = id
    }

    func destinations() -> [Destination] { store.destinations }
    func saveDestination(_ d: Destination) async { store.upsert(d) }
    func deleteDestination(id: String) async { store.removeDestination(id) }

    var integrationStore: StudioStore? { store }
    func goLive(record: Bool, destinationIDs: [String]) async throws { try await goLive(record: record, destinationIDs: destinationIDs, extraDestinations: []) }
    func goLive(record: Bool, destinationIDs: [String], extraDestinations: [Destination]) async throws {
        guard !live else { return }
        guard let ff = FFmpegLocator.locate() else { throw ServiceError(message: "ffmpeg was not found. Install it with `brew install ffmpeg` or bundle it into the app.") }
        let dests = store.destinations.filter { destinationIDs.contains($0.id) } + extraDestinations
        var cfg = OutputConfig(ffmpegPath: ff)
        cfg.destinations = dests
        cfg.recordHEVC = recordHEVC && record
        if record {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
            let name = "7XEN-\(f.string(from: Date())).mp4"
            cfg.recordingURL = store.recordingsDir.appendingPathComponent(name); recordingFile = name
        } else { recordingFile = nil }
        try output.start(cfg)
        activeDests = dests; live = true; liveSince = Date(); recScanned = .distantPast
        engine.setLiveClock(since: liveSince)
    }
    func stopLive() async {
        guard live else { return }
        live = false; liveSince = nil; engine.setLiveClock(since: nil)
        let finished = recordingFile.map { store.recordingsDir.appendingPathComponent($0) }
        await output.stop()
        if let finished, let ff = FFmpegLocator.locate() { Task.detached { Self.finalizeRecording(finished, ffmpeg: ff) } }
        recordingFile = nil; activeDests = []; recScanned = .distantPast
    }
    /// Live recordings are fragmented MP4 (crash safe, but AVFoundation reports only the first fragment's duration and
    /// seeking is poor): once the show ends, remux (stream copy) into a regular faststart MP4.
    nonisolated static func finalizeRecording(_ url: URL, ffmpeg: String) {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).finalizing.mp4")
        let p = Process(); p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-y", "-i", url.path, "-c", "copy", "-movflags", "+faststart", tmp.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
        let fm = FileManager.default
        if p.terminationStatus == 0, let a = try? fm.attributesOfItem(atPath: tmp.path)[.size] as? Int64, a > 0, fm.fileExists(atPath: url.path) {
            _ = try? fm.replaceItemAt(url, withItemAt: tmp)
        }
        try? fm.removeItem(at: tmp)
    }
    func stats() -> StudioStats {
        let o = output.stats
        var s = StudioStats()
        s.live = live; s.liveSince = liveSince; s.recordingFile = recordingFile
        s.fps = live ? engine.fps : 0; s.kbps = live ? o.kbps : 0; s.dropped = o.droppedFrames
        s.error = o.error ?? lastError ?? ingest.lastError
        s.audioPeak = engine.audio.peak
        if Self.logStats, Date().timeIntervalSince(lastStatLog) >= 1 {
            lastStatLog = Date(); let e = engine.stats
            NSLog("ENGINE fps=%.1f missed=%d held=%d gpuAvg=%.2fms gpuP99=%.2fms frameP99=%.2fms", e.fps, e.missedDeadlines, e.heldFrames, e.gpuAvgMs, e.gpuP99Ms, e.frameP99Ms)
        }
        s.restarts = o.restarts; s.recordHEVC = live && recordHEVC && recordingFile != nil
        s.encoder = s.recordHEVC ? "VideoToolbox H.264 + HEVC rec (hardware)" : "VideoToolbox H.264 (hardware)"
        if live { s.outputs = activeDests.map { d in OutputHealth(id: d.id, name: d.name, ok: o.destinationErrors[d.name] == nil, error: o.destinationErrors[d.name]) } }
        return s
    }

    /// The directory scan (+ per-file attributes) is the expensive part and runs on the main thread (AppModel polls every 0.5 s),
    /// so it is cached for 2 s and invalidated on delete / go live / stop; only the live file's duration is recomputed per call.
    private var recCache: [RecordingInfo] = [], recScanned = Date.distantPast
    func recordings() -> [RecordingInfo] {
        if Date().timeIntervalSince(recScanned) > 2 || recCache.isEmpty && recScanned == .distantPast { recCache = scanRecordings(); recScanned = Date() }
        guard live, let rec = recordingFile else { return recCache }
        return recCache.map { r in
            guard r.file == rec else { return r }
            var r = r; r.isRecording = true; r.duration = Date().timeIntervalSince(liveSince ?? r.startedAt); return r
        }
    }
    private func scanRecordings() -> [RecordingInfo] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: store.recordingsDir, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "mp4" && !$0.lastPathComponent.hasPrefix(".") }.compactMap { u in
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
            let start = v?.creationDate ?? Date(), end = v?.contentModificationDate ?? start
            let name = u.lastPathComponent, size = Int64(v?.fileSize ?? 0)
            let recording = live && name == recordingFile
            var dur = max(0, end.timeIntervalSince(start))
            if recording { dur = Date().timeIntervalSince(liveSince ?? start) }
            else if let d = duration(of: u, size: size) { dur = max(d, dur) }   // fragmented (crashed) files report a short AV duration
            return RecordingInfo(file: name, title: u.deletingPathExtension().lastPathComponent, startedAt: start,
                                 duration: dur, sizeBytes: size, url: u, isRecording: recording)
        }.sorted { $0.startedAt > $1.startedAt }
    }
    /// Cached duration read from the file (AVURLAsset); nil until the background load finishes.
    private func duration(of url: URL, size: Int64) -> TimeInterval? {
        let key = url.lastPathComponent
        cache.lock.lock()
        if let c = cache.durations[key], c.size == size { cache.lock.unlock(); return c.secs }
        let start = cache.durationPending.insert(key).inserted
        cache.lock.unlock()
        if start {
            let c = cache
            Task.detached {
                let d = (try? await AVURLAsset(url: url).load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
                c.store(duration: d, key: key, size: size)
            }
        }
        return nil
    }
    /// volumeAvailableCapacityForImportantUsage costs ~10 ms (purgeable-space query) and AppModel polls every 0.5 s on the main
    /// thread, so it is refreshed in the background every 15 s and served from memory.
    private var diskInfo = DiskInfo(freeBytes: 0, totalBytes: 0), diskStamp = Date.distantPast, diskBusy = false
    func disk() -> DiskInfo {
        if !diskBusy, Date().timeIntervalSince(diskStamp) > 15 {
            diskBusy = true
            let dir = store.dir
            Task.detached(priority: .utility) { [weak self] in
                let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
                let d = DiskInfo(freeBytes: v?.volumeAvailableCapacityForImportantUsage ?? 0, totalBytes: Int64(v?.volumeTotalCapacity ?? 0))
                await MainActor.run { self?.diskInfo = d; self?.diskStamp = Date(); self?.diskBusy = false }
            }
        }
        return diskInfo
    }
    func deleteRecording(file: String) async {
        guard file != recordingFile || !live else { return }
        try? FileManager.default.removeItem(at: store.recordingsDir.appendingPathComponent(file)); recScanned = .distantPast
    }

    // MARK: props
    func props() -> [PropInfo] {
        store.props.compactMap { p in store.propURL(p.id).map { PropInfo(id: p.id, name: p.name, isVideo: p.kind == .video, sizeBytes: p.sizeBytes, url: $0) } }
    }
    func addProp(url: URL) async throws {
        do { _ = try store.addProp(file: url) } catch let e as CoreError { throw ServiceError(message: e.message) }
    }
    func renameProp(id: String, name: String) async { store.renameProp(id, name: name) }
    func deleteProp(id: String) async {
        if introPropId == id { introPropId = nil }
        ingest.sourceProvider.release(.prop(id: id)); ingest.sourceProvider.release(.image(id: id))
        store.removeProp(id)
        cache.store(thumb: nil, id: id); cache.drop(id)
    }
    func propThumbnail(id: String) -> CGImage? {
        cache.lock.lock()
        if let t = cache.thumbs[id] { cache.lock.unlock(); return t }
        let start = cache.thumbPending.insert(id).inserted
        cache.lock.unlock()
        guard start, let p = store.props.first(where: { $0.id == id }), let url = store.propURL(id) else { return nil }
        let c = cache
        Task.detached {
            var img: CGImage?
            if p.kind == .image {
                if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 320] as CFDictionary)
                }
            } else {
                let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                g.appliesPreferredTrackTransform = true; g.maximumSize = CGSize(width: 320, height: 320)
                img = try? await g.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
            }
            c.store(thumb: img, id: id)
        }
        return nil
    }

    /// 18 ms: a frame is shown once its tick is more than ~one frame old, by which time the GPU has long finished it (frame p99 < 14 ms).
    func pacedFrame(_ m: MonitorKind, at target: Double, cursor: inout Int64?) -> (frame: MonitorFrame, id: Int64)? {
        guard m == .program, let r = programBox.paced(target: target, delay: 0.018, fps: Double(defaultFPS), cursor: &cursor) else { return nil }
        return (.pixels(r.0), r.1)
    }
    func frameSerial(_ m: MonitorKind) -> UInt64 { (m == .program ? programBox : previewBox).serial }
    func frame(_ m: MonitorKind) -> MonitorFrame? {
        (m == .program ? programBox : previewBox).get().map { .pixels($0) }
    }

    func shutdown() async {
        pollTask?.cancel()
        audio?.shutdown()
        await stopLive()
        engine.stop()
        store.flushOverlays()
        ingest.stop()
    }
}

@MainActor func realServicesIfAvailable() -> StudioServices? {
    do { return RealServices(ingest: Stress.uiRequested ? try Stress.uiIngest() : try IngestService()) }
    catch { NSLog("7XEN Studio: store failed to open: \(error)"); return nil }
}
