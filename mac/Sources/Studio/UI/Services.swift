// UI-facing service boundary. The UI only talks to `StudioServices`; MockServices runs the app standalone,
// RealServices (UI/RealServices.swift) adapts Core/Ingest/Engine/Output.
import Foundation
import CoreGraphics
import CoreVideo
import QuartzCore

struct DeviceInfo: Identifiable, Hashable {
    var id: String
    var name: String
    var online = false
    var streaming = false
    var videoReady = false
    var battery: Int? = nil
    var model: String? = nil
    /// Live source quality (decoded picture size, decoded fps, measured incoming video bitrate, phone-reported values)
    var width = 0, height = 0
    var decodedFPS = 0.0
    var ingestKbps = 0.0
    var reportedKbps: Double? = nil
    var quality: String? = nil
    var autoDowngraded = false
    var network: String? = nil
    /// Effective rotation (degrees clockwise) / flip applied in the compositor; `rotationAuto` = no manual choice (phone-reported or none)
    var rotation = 0
    var flip = false
    var rotationAuto = true
}
extension DeviceInfo {
    /// "1080p · 4.2 Mbps"
    var qualityLabel: String? {
        guard videoReady, height > 0 else { return nil }
        let r = "\(min(width, height))p"      // portrait phones report 1080x1920
        let mb = ingestKbps > 0 ? String(format: " · %.1f Mbps", ingestKbps / 1000) : ""
        return r + mb
    }
    var lowQuality: Bool { videoReady && ((height > 0 && min(width, height) < 720) || autoDowngraded) }
    /// Amber warning text, nil when the source is fine.
    var qualityWarning: String? {
        guard lowQuality else { return nil }
        let r = height > 0 ? "\(min(width, height))p" : "low-res"
        let mb = ingestKbps > 0 ? String(format: " · %.1f Mbps", ingestKbps / 1000) : ""
        return "\(r)\(mb) — phone is sending low quality" + (autoDowngraded ? " (auto-downgraded: Wi-Fi/heat)" : "") + ". Set the phone to 1080p, move closer to the router (5 GHz) or use a cable."
    }
    /// Ingest health hint: measured bitrate far below what this picture size normally needs.
    var ingestHint: String? {
        guard videoReady, height > 0, ingestKbps > 0, decodedFPS > 0 else { return nil }
        let expected = Double(width * height) * max(24, min(60, decodedFPS)) * 0.04 / 1000    // ~4% of a bit per pixel
        if ingestKbps < expected * 0.35 { return String(format: "Low ingest bitrate (%.1f Mbps for %dp): Wi-Fi may be congested.", ingestKbps / 1000, min(width, height)) }
        if decodedFPS < 24 { return String(format: "Only %.0f fps arriving: check Wi-Fi / phone heat.", decodedFPS) }
        return nil
    }
}

struct PairingInfo {
    var device: DeviceInfo
    var pairURL: String
    var key: String
}

struct RecordingInfo: Identifiable, Hashable {
    var id: String { file }
    var file: String
    var title: String
    var startedAt: Date
    var duration: TimeInterval
    var sizeBytes: Int64
    var url: URL
    var isRecording = false
}

struct PropInfo: Identifiable, Hashable {
    var id: String
    var name: String
    var isVideo: Bool
    var sizeBytes: Int64
    var url: URL
}

struct DiskInfo: Equatable { var freeBytes: Int64; var totalBytes: Int64 }

struct StudioStats: Equatable {
    var fps = 0.0, kbps = 0.0, dropped = 0
    var error: String? = nil
    var live = false
    var liveSince: Date? = nil
    var recordingFile: String? = nil
    var encoder: String = "VideoToolbox H.264"
    var restarts = 0
    var recordHEVC = false
    var targetKbps = 0
    var outputs: [OutputHealth] = []
    /// Program audio peak 0...1 for meters (0 until the backend reports it).
    var audioPeak: Float = 0
}
struct OutputHealth: Identifiable, Hashable { var id: String; var name: String; var ok: Bool; var error: String? = nil }

typealias StillRenderer = @Sendable (LayerScene, CGSize, SceneVariables, Double, AnimClock?) -> CGImage?
enum MonitorKind { case program, preview }
enum TransitionKind: String, CaseIterable { case cut = "Cut", fade = "Fade" }

/// A frame the monitor view can draw.
enum MonitorFrame { case image(CGImage), pixels(CVPixelBuffer) }

struct ServiceError: LocalizedError { var message: String; var errorDescription: String? { message } }

@MainActor
protocol StudioServices: AnyObject {
    // Studio
    var studioName: String { get }
    var lanURL: String { get }
    func setStudioName(_ n: String) async throws

    // Phones
    func devices() -> [DeviceInfo]
    func createDevice(name: String) async throws -> PairingInfo
    func deleteDevice(id: String) async

    // Scenes
    func scenes() -> [Scene]
    func saveScene(_ s: Scene) async
    func deleteScene(id: String) async
    var programSceneID: String? { get }
    var previewSceneID: String? { get }
    func setPreview(sceneID: String)
    func take(_ t: TransitionKind)

    // Overlays
    var overlays: Overlays { get set }

    // Output
    func destinations() -> [Destination]
    func saveDestination(_ d: Destination) async
    func deleteDestination(id: String) async
    func goLive(record: Bool, destinationIDs: [String]) async throws
    /// additive: destinations that are not saved (e.g. the YouTube ingest from AirBattleground); keys are never persisted
    func goLive(record: Bool, destinationIDs: [String], extraDestinations: [Destination]) async throws
    func stopLive() async
    func stats() -> StudioStats

    // Recordings
    func recordings() -> [RecordingInfo]
    func disk() -> DiskInfo
    func deleteRecording(file: String) async

    // Props + slate (additive; defaults below keep MockServices working)
    func props() -> [PropInfo]
    func addProp(url: URL) async throws
    func renameProp(id: String, name: String) async
    func deleteProp(id: String) async
    func propThumbnail(id: String) -> CGImage?
    var slateText: String { get set }
    var introPropId: String? { get set }
    /// Fade transition length in milliseconds.
    var transitionMs: Int { get set }

    // Monitors
    func frame(_ m: MonitorKind) -> MonitorFrame?
    /// Increments whenever `frame(m)` has a new picture (0 = unknown, treat every poll as new).
    func frameSerial(_ m: MonitorKind) -> UInt64
    /// Frame for the display refresh that will show at `target` (CACurrentMediaTime seconds), or nil when the backend does not pace.
    func pacedFrame(_ m: MonitorKind, at target: Double, cursor: inout Int64?) -> (frame: MonitorFrame, id: Int64)?
    /// Commentary audio (mic, mixer, monitor). nil in the mock backend.
    var audio: AudioController? { get }
    /// Operator rotation (0/90/180/270) and flip for a phone; rotation nil = automatic.
    func setDeviceTransform(id: String, rotation: Int?, flip: Bool?)
    /// "Vivid" final-pass enhancement, video bitrate preset (kbps) and HEVC local recording (applied at the next Go Live).
    var vividLevel: VividLevel { get set }
    var videoKbps: Int { get set }
    var recordHEVC: Bool { get set }
    /// additive: the Core store, for integrations that persist (nil in the mock backend)
    var integrationStore: StudioStore? { get }
    /// additive (layer scenes): all scenes as layer scenes, save / delete, still render for thumbnails, live {{variables}}
    func layerScenes() -> [LayerScene]
    func saveLayerScene(_ s: LayerScene) async
    func deleteLayerScene(id: String) async
    func renderStill(_ s: LayerScene, size: CGSize) -> CGImage?
    /// Thread-safe still renderer for background work (thumbnails, the editor canvas): scene, size, variables, time, animation clock (nil = animations at rest).
    func stillRenderer() -> StillRenderer
    /// additive (auto capture): renders a scene as it looks on air right now (live sources, live {{variables}}, loops at the current time). Thread-safe.
    func captureRenderer() -> CaptureRenderer
    /// additive (YouTube thumbnail): the {{variables}} the engine shows right now.
    func liveSceneVariables() -> SceneVariables
    /// Bumped whenever any layer scene is saved / deleted / migrated, so cached thumbnails and subtitles can refresh.
    var layerSceneRevision: Int { get }
    func setSceneVariables(_ v: [String: String])
    /// Editor live update: swap the scene on Program / Preview without restarting its animations (no persistence).
    func pushLive(_ s: LayerScene)
    func isOnAir(sceneID: String) -> Bool
    /// Take a scene straight to Program with its own transition (`.cut` forces a hard cut).
    func takeScene(id: String, _ t: TransitionKind)
    /// additive (scene delete): program goes to black (no scene), e.g. before deleting the on-air scene.
    func cutToBlack()
    /// One-shot on-air animations (kill pop-up, flash, ...).
    func fireTrigger(_ id: String)
    /// Replays the program scene from its first frame (looping pre-show stinger).
    func replayProgram()
    func resetKillStreak()
    /// Phones were added or removed: fill empty phone slots of the starter scenes.
    func autoAssignSources()
    func shutdown() async
}

extension StudioServices {
    // Layer scenes (additive; mock backend migrates the old scenes)
    func layerScenes() -> [LayerScene] { scenes().map { LayerScene.migrate($0) } }
    func saveLayerScene(_ s: LayerScene) async {}
    func deleteLayerScene(id: String) async {}
    func renderStill(_ s: LayerScene, size: CGSize) -> CGImage? { StudioEngine.shared.renderStill(s, size: size) }
    func stillRenderer() -> StillRenderer { { s, size, vars, t, clock in StudioEngine.shared.renderStill(s, size: size, variables: vars, time: t, clock: clock) } }
    func captureRenderer() -> CaptureRenderer { { s, size in StudioEngine.shared.renderStill(s, size: size, time: CACurrentMediaTime()) } }
    var layerSceneRevision: Int { 0 }
    func liveSceneVariables() -> SceneVariables { SceneVariables() }
    func pushLive(_ s: LayerScene) {}
    func isOnAir(sceneID: String) -> Bool { programSceneID == sceneID }
    func takeScene(id: String, _ t: TransitionKind) { setPreview(sceneID: id); take(t) }
    func cutToBlack() {}
    func fireTrigger(_ id: String) {}
    func replayProgram() {}
    func resetKillStreak() {}
    func autoAssignSources() {}
    func setSceneVariables(_ v: [String: String]) {}
    func goLive(record: Bool, destinationIDs: [String], extraDestinations: [Destination]) async throws { try await goLive(record: record, destinationIDs: destinationIDs) }
    var integrationStore: StudioStore? { nil }
    func frameSerial(_ m: MonitorKind) -> UInt64 { 0 }
    func pacedFrame(_ m: MonitorKind, at target: Double, cursor: inout Int64?) -> (frame: MonitorFrame, id: Int64)? { nil }
    func props() -> [PropInfo] { [] }
    func addProp(url: URL) async throws { throw ServiceError(message: "Props are not available in the mock backend") }
    func renameProp(id: String, name: String) async {}
    func deleteProp(id: String) async {}
    func propThumbnail(id: String) -> CGImage? { nil }
    var slateText: String { get { "Starting soon" } set {} }
    var introPropId: String? { get { nil } set {} }
    var transitionMs: Int { get { 300 } set {} }
    var audio: AudioController? { nil }
    func setDeviceTransform(id: String, rotation: Int?, flip: Bool?) {}
    var vividLevel: VividLevel { get { .subtle } set {} }
    var videoKbps: Int { get { defaultVideoKbps } set {} }
    var recordHEVC: Bool { get { false } set {} }
}
