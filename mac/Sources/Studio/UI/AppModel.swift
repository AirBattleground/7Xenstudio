import SwiftUI
import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    @ObservationIgnored var services: StudioServices
    /// AirBattleground link (Integrations/AirBattleground): connection, match, YouTube ingest
    let abg: ABGController
    /// AirBattleground auto capture (Studio page -> Capture tab)
    let capture: AutoCaptureController
    /// AirBattleground YouTube thumbnail (Go Live sheet + Outputs)
    let thumbnail: ThumbnailController

    var devices: [DeviceInfo] = []
    /// Scenes of the ACTIVE preset, in its order (Studio strip, hotkeys 1-9, Scenes page). `allScenes` = every scene in the studio.
    var scenes: [Scene] = []
    var allScenes: [Scene] = []
    /// Studio presets (Core/Presets.swift) and the match journey (auto-follow, toast) - see AppModel+Presets.swift
    var presetBook = PresetBook()
    var journey = JourneyAutoFollow()
    var autoSwitch: PendingAutoSwitch?
    /// Stage whose scene auto-follow put on Program last (AUTO badge); cleared by a manual take.
    var autoTakenStage: JourneyStage?
    @ObservationIgnored var lastPreShowReplay = Date.distantPast
    /// Auto-start: the match id it was already tried for (never retried automatically; the operator can press Start).
    @ObservationIgnored var autoStartTriedFor: String?
    var autoStartMatch = true
    var matchStatus = MatchDataStore.Status()
    @ObservationIgnored var knownSceneIds: Set<String>?
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
    var vividLevel = VividLevel.subtle { didSet { if vividLevel != oldValue { services.vividLevel = vividLevel } } }
    var videoKbps = defaultVideoKbps { didSet { if videoKbps != oldValue { services.videoKbps = videoKbps } } }
    var recordHEVC = false { didSet { if recordHEVC != oldValue { services.recordHEVC = recordHEVC } } }
    var selectedDestinations: Set<String> = []
    var errorMessage: String?
    var busy = false

    var editingScene: Scene?
    var showNewScene = false
    /// Bumped when any layer scene is saved: thumbnails refresh on it.
    var sceneRevision = 0
    @ObservationIgnored private var triggerMonitor: Any?
    var showAddPhone = false
    var showStreamKey = false
    var showGoLiveConfirm = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastSceneVars: [String: String] = [:]

    init(services: StudioServices) {
        self.services = services
        abg = StudioIntegrations.makeAirBattleground(store: services.integrationStore)
        capture = StudioIntegrations.makeAutoCapture(abg: abg, services: services)
        thumbnail = StudioIntegrations.makeThumbnail(abg: abg, services: services)
        abg.statusProvider = { [weak self] in self?.abgHeartbeatStatus() ?? ABGHeartbeat(state: "starting", fps: nil, bitrateKbps: nil) }
        abg.onRemoteStop = { [weak self] in self?.stopLive() }
        loadPresets()
        MatchDataStore.shared.start()
        // dev hook for screenshots / rehearsal: STUDIO_MATCH_SIMULATE=scheduled|live|summary|finished
        if let sim = ProcessInfo.processInfo.environment["STUDIO_MATCH_SIMULATE"], MatchDataStore.simulatedStates.contains(sim) { MatchDataStore.shared.simulate(sim) }
        journey = JourneyAutoFollow(enabled: services.integrationStore?.settings.journeyAutoFollow ?? false)
        autoStartMatch = services.integrationStore?.settings.autoStartMatch ?? true
        refresh()
        overlays = services.overlays
        vividLevel = services.vividLevel; videoKbps = services.videoKbps; recordHEVC = services.recordHEVC
        transitionMs = services.transitionMs
        triggerMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, self.editingScene == nil, !e.isARepeat,
                      e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      !(NSApp.keyWindow?.firstResponder is NSText), NSApp.keyWindow?.attachedSheet == nil,
                      let d = StudioTriggers.def(forKey: e.charactersIgnoringModifiers ?? "") else { return e }
                self.services.fireTrigger(d.id); return nil
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var program: Scene? { allScenes.first { $0.id == programID } }
    var preview: Scene? { allScenes.first { $0.id == previewID } }
    var isLive: Bool { live }

    /// Polled every 0.5 s on the main thread: only touch observed properties whose value actually changed
    /// (an @Observable setter invalidates every dependent view even when the new value is equal).
    func refresh() {
        func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<AppModel, T>, _ v: T) { if self[keyPath: kp] != v { self[keyPath: kp] = v } }
        set(\.devices, services.devices())
        let all = services.scenes()
        set(\.allScenes, all)
        syncPresets(all)
        set(\.scenes, presetBook.scenes(all))
        set(\.programID, services.programSceneID)
        set(\.previewID, services.previewSceneID)
        set(\.sceneRevision, services.layerSceneRevision)
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
        // {{bindings}} in layer scenes: AirBattleground match + on-air timer (operator-set keys stay in the engine)
        if TeamBoardHub.shared.abgMatchId != abg.link?.eventId { TeamBoardHub.shared.abgMatchId = abg.link?.eventId }
        var vars = SceneVariables.fromMatch(abg.link)
        // server match data (one shared poller with the Team Status board) or the operator's "Simulate" state
        let match = MatchDataStore.shared
        // AirBattleground match control (picker list, start / stop answers) -> journey stage + countdown target
        let ctl = abg.selectedControl
        match.setControl(state: ctl?.state.rawValue, unlocksAt: ctl?.unlocksAtDate)
        for (k, v) in match.variables() { vars[k] = v }
        set(\.matchStatus, match.status)
        vars["timer"] = SceneVariables.clock(liveSince.map { Int(Date().timeIntervalSince($0)) } ?? 0)
        if vars != lastSceneVars {
            var send = vars
            for k in lastSceneVars.keys where vars[k] == nil { send[k] = "" }     // data that went away (match changed, simulate off)
            lastSceneVars = vars; services.setSceneVariables(send)
        }
        tickJourney(state: matchStatus.state)
        tickAutoStart()
    }

    // MARK: scenes
    func select(index: Int) { if scenes.indices.contains(index) { select(scenes[index]) } }
    func select(_ s: Scene) { services.setPreview(sceneID: s.id); previewID = s.id }
    func take() {
        guard let p = previewID, p != programID else { return }
        noteManualTake(p)
        services.take(transition); programID = services.programSceneID
    }
    func takeScene(_ s: Scene) { select(s); take() }
    /// Opens the simple "New scene" window (pick a video/picture, phone, webcam or template).
    func newScene() { showNewScene = true }
    /// Saves a ready-made layer scene and puts it on Preview (NEXT), so the next TAKE puts it on air.
    func createScene(_ ls: LayerScene) {
        Task {
            await services.saveLayerScene(ls)
            await services.saveScene(Scene(id: ls.id, name: ls.name, layout: .full, slots: [nil]))
            refresh()
            services.setPreview(sceneID: ls.id); previewID = ls.id
            refresh()
        }
    }
    /// One click from the Props page: a full-screen scene showing this prop.
    func createScene(from p: PropInfo) {
        createScene(LayerScene(name: p.name, background: .solid(RGBA(hex: 0x000000)),
                               layers: [.source(p.name, .prop(id: p.id), x: 0, y: 0, w: 1920, h: 1080, fit: .fill)]))
    }
    func save(_ s: Scene) { Task { await services.saveScene(s); refresh() } }
    func fire(_ id: String) { services.fireTrigger(id) }
    func delete(_ s: Scene) {
        var b = presetBook; b.sceneDeleted(s.id)
        if b != presetBook { presetBook = b; persistPresets() }
        Task { await services.deleteScene(id: s.id); refresh() }
    }

    // MARK: phones / outputs
    /// rotation nil = automatic (phone-reported, else none)
    func setTransform(_ d: DeviceInfo, rotation: Int?, flip: Bool) { services.setDeviceTransform(id: d.id, rotation: rotation, flip: flip); refresh() }
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
