import SwiftUI
import Observation

@MainActor
@Observable
final class AppModel {
    @ObservationIgnored var services: StudioServices
    /// AirBattleground link (Integrations/AirBattleground): connection, match, YouTube ingest
    let abg: ABGController

    var devices: [DeviceInfo] = []
    var scenes: [Scene] = []
    var programID: String?
    var previewID: String?
    var overlays = Overlays() { didSet { if overlays != oldValue { services.overlays = overlays } } }
    var destinations: [Destination] = []
    var recordings: [RecordingInfo] = []
    var props: [PropInfo] = []
    var slateText = ""
    var introPropId: String?
    var disk = DiskInfo(freeBytes: 0, totalBytes: 0)
    var stats = StudioStats()
    /// Fine-grained mirrors of fast-changing / widely-read fields: SwiftUI invalidates per stored property, so views that only need
    /// the live clock origin, the recording flag or the meter level no longer re-render every time fps/kbps tick.
    var liveSince: Date?
    var recordingFile: String?
    var audioPeak: Float = 0
    var live = false
    var studioName = ""
    var lanURL = ""
    var transition: TransitionKind = .cut
    var recordOn = true
    /// Fade length for AUTO transitions (ms); forwarded to the engine.
    var transitionMs = 300 { didSet { if transitionMs != oldValue { services.transitionMs = transitionMs } } }
    var selectedDestinations: Set<String> = []
    var errorMessage: String?
    var busy = false

    var editingScene: Scene?
    var showAddPhone = false
    var showStreamKey = false
    var showGoLiveConfirm = false

    @ObservationIgnored private var timer: Timer?

    init(services: StudioServices) {
        self.services = services
        abg = StudioIntegrations.makeAirBattleground(store: services.integrationStore)
        abg.statusProvider = { [weak self] in self?.abgHeartbeatStatus() ?? ABGHeartbeat(state: "starting", fps: nil, bitrateKbps: nil) }
        abg.onRemoteStop = { [weak self] in self?.stopLive() }
        refresh()
        overlays = services.overlays
        transitionMs = services.transitionMs
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var program: Scene? { scenes.first { $0.id == programID } }
    var preview: Scene? { scenes.first { $0.id == previewID } }
    var isLive: Bool { live }

    /// Polled every 0.5 s on the main thread: only touch observed properties whose value actually changed
    /// (an @Observable setter invalidates every dependent view even when the new value is equal).
    func refresh() {
        func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<AppModel, T>, _ v: T) { if self[keyPath: kp] != v { self[keyPath: kp] = v } }
        set(\.devices, services.devices())
        set(\.scenes, services.scenes())
        set(\.programID, services.programSceneID)
        set(\.previewID, services.previewSceneID)
        set(\.destinations, services.destinations())
        var s = services.stats()
        set(\.audioPeak, s.audioPeak)
        set(\.live, s.live)
        set(\.liveSince, s.liveSince)
        set(\.recordingFile, s.recordingFile)
        s.audioPeak = 0
        set(\.stats, s)
        set(\.studioName, services.studioName)
        set(\.lanURL, services.lanURL)
        set(\.recordings, services.recordings())
        set(\.props, services.props())
        if slateText != services.slateText { slateText = services.slateText }
        set(\.introPropId, services.introPropId)
        set(\.disk, services.disk())
    }

    // MARK: scenes
    func select(index: Int) { if scenes.indices.contains(index) { select(scenes[index]) } }
    func select(_ s: Scene) { services.setPreview(sceneID: s.id); previewID = s.id }
    func take() {
        guard let p = previewID, p != programID else { return }
        services.take(transition); programID = services.programSceneID
    }
    func takeScene(_ s: Scene) { select(s); take() }
    func newScene() {
        editingScene = Scene(id: UUID().uuidString, name: "Scene \(scenes.count + 1)", layout: .full, slots: [nil])
    }
    func save(_ s: Scene) { Task { await services.saveScene(s); refresh() } }
    func delete(_ s: Scene) { Task { await services.deleteScene(id: s.id); refresh() } }

    // MARK: phones / outputs
    func removeDevice(_ d: DeviceInfo) { Task { await services.deleteDevice(id: d.id); refresh() } }
    func saveDestination(_ d: Destination) { Task { await services.saveDestination(d); selectedDestinations.insert(d.id); refresh() } }
    func removeDestination(_ d: Destination) { Task { await services.deleteDestination(id: d.id); selectedDestinations.remove(d.id); refresh() } }

    func goLive() {
        busy = true
        Task {
            defer { busy = false; refresh() }
            do { try await services.goLive(record: recordOn, destinationIDs: Array(selectedDestinations)) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func stopLive() { busy = true; Task { await services.stopLive(); busy = false; refresh(); await abg.endBroadcast() } }
    func deleteRecording(_ r: RecordingInfo) { Task { await services.deleteRecording(file: r.file); refresh() } }
    func rename(_ n: String) { Task { do { try await services.setStudioName(n) } catch { errorMessage = error.localizedDescription }; refresh() } }
    func addProps(_ urls: [URL]) {
        Task {
            var errs: [String] = []
            for u in urls {
                let scoped = u.startAccessingSecurityScopedResource(); defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                do { try await services.addProp(url: u) } catch { errs.append("\(u.lastPathComponent): \(error.localizedDescription)") }
            }
            if !errs.isEmpty { errorMessage = errs.joined(separator: "\n") }
            refresh()
        }
    }
    func renameProp(_ p: PropInfo, _ n: String) { Task { await services.renameProp(id: p.id, name: n); refresh() } }
    func deleteProp(_ p: PropInfo) { Task { await services.deleteProp(id: p.id); refresh() } }
    func setSlateText(_ t: String) { slateText = t; services.slateText = t }
    func setIntroProp(_ id: String?) { introPropId = id; services.introPropId = id }
    func shutdown() async { await services.shutdown(); await abg.endBroadcast() }
}

func formatDuration(_ secs: TimeInterval) -> String {
    let s = max(0, Int(secs)); let h = s / 3600, m = (s % 3600) / 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s % 60) : String(format: "%d:%02d", m, s % 60)
}
