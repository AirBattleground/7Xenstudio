// YouTube thumbnail for the admin's broadcast: which picture (the "YouTube Thumbnail" scene, any scene, or a file),
// rendering it (1280x720, entrance animations finished, current {{variables}}), and uploading it through AirBattleground
// once after Go Live (Admin YouTube) or on request.
import Foundation
import CoreGraphics
import Observation

/// Where the thumbnail picture comes from.
enum ThumbnailSource: Codable, Hashable, Sendable {
    /// the built-in "YouTube Thumbnail" scene (the stored copy when it exists, else a fresh one)
    case builtin
    /// any layer scene, rendered at 1280x720
    case scene(String)
    /// a PNG / JPG on this Mac (absolute path)
    case file(String)
}

struct ThumbnailSettings: Codable, Hashable, Sendable {
    var source: ThumbnailSource = .builtin
    /// "Set automatically when going live"
    var autoSet = true
    init(source: ThumbnailSource = .builtin, autoSet: Bool = true) { self.source = source; self.autoSet = autoSet }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        source = ((try? c.decodeIfPresent(ThumbnailSource.self, forKey: .source)) ?? nil) ?? .builtin
        autoSet = ((try? c.decodeIfPresent(Bool.self, forKey: .autoSet)) ?? nil) ?? true
    }
    private enum K: String, CodingKey { case source, autoSet }
}

@MainActor protocol ThumbnailPersistence: AnyObject { var settings: ThumbnailSettings { get set } }
@MainActor final class ThumbnailMemoryPersistence: ThumbnailPersistence { var settings = ThumbnailSettings() }
@MainActor final class ThumbnailStorePersistence: ThumbnailPersistence {
    let store: StudioStore
    init(store: StudioStore) { self.store = store }
    var settings: ThumbnailSettings {
        get { store.settings.youtubeThumbnail ?? ThumbnailSettings() }
        set { store.update { $0.settings.youtubeThumbnail = newValue } }
    }
}

/// What the thumbnail needs from the studio. Closures so tests run without the app.
struct ThumbnailEnvironment {
    var scenes: @MainActor () -> [LayerScene]
    /// the live {{variables}} (match data) right now
    var variables: @MainActor () -> SceneVariables
    /// thread-safe still renderer (scene, size, variables, time, clock)
    var render: StillRenderer
    var upload: @Sendable (ThumbnailUpload) async -> ThumbnailReply
    /// the open AirBattleground broadcast (nil when not live to the admin's YouTube)
    var broadcastId: @MainActor () -> String?
    var matchId: @MainActor () -> String?
}

@MainActor @Observable
final class ThumbnailController {
    enum Status: Equatable {
        case idle
        case working(String)
        case set(url: String?, at: Date)
        /// amber: the server's (or our) message
        case failed(String)
        /// 501: shown quietly, never retried
        case unsupported
        var text: String? {
            switch self {
            case .idle: nil
            case .working(let s): s
            case .set: ThumbnailReply.set(url: nil).message
            case .failed(let m): m
            case .unsupported: ThumbnailReply.unsupported.message
            }
        }
    }
    /// retries after the first attempt (5xx / timeouts only)
    nonisolated static let maxRetries = 3

    @ObservationIgnored let env: ThumbnailEnvironment
    @ObservationIgnored private let persistence: ThumbnailPersistence
    var settings: ThumbnailSettings { didSet { if settings != oldValue { persistence.settings = settings; if settings.source != oldValue.source { previewStale = true } } } }
    private(set) var preview: CGImage?
    private(set) var previewBytes: Int?
    private(set) var previewError: String?
    private(set) var rendering = false
    private(set) var uploading = false
    private(set) var status: Status = .idle
    /// set when the preview no longer matches the source (views re-render on appear / change)
    private(set) var previewStale = true
    /// first retry waits this long, doubling each time
    @ObservationIgnored var retryDelay: Double = 2
    /// the auto upload started by `broadcastStarted` (tests await it)
    @ObservationIgnored private(set) var autoTask: Task<Void, Never>?

    init(env: ThumbnailEnvironment, persistence: ThumbnailPersistence? = nil) {
        self.env = env
        self.persistence = persistence ?? ThumbnailMemoryPersistence()
        settings = self.persistence.settings
    }

    // MARK: source

    var isLive: Bool { env.broadcastId() != nil }
    /// Scenes offered in the picker (the built-in thumbnail scene is the first, separate entry).
    var pickableScenes: [LayerScene] { env.scenes().filter { $0.id != AdvancedStudioPreset.thumbnailId } }
    var sourceTitle: String {
        switch settings.source {
        case .builtin: AdvancedStudioPreset.thumbnailName
        case .scene(let id): env.scenes().first { $0.id == id }?.name ?? "Missing scene"
        case .file(let p): URL(fileURLWithPath: p).lastPathComponent
        }
    }
    /// The scene for `.builtin` / `.scene` (a deleted scene falls back to the built-in design).
    func scene(for source: ThumbnailSource) -> LayerScene? {
        let all = env.scenes()
        switch source {
        case .file: return nil
        case .scene(let id): if let s = all.first(where: { $0.id == id }) { return s }
        case .builtin: break
        }
        return all.first { $0.id == AdvancedStudioPreset.thumbnailId } ?? AdvancedStudioPreset.youtubeThumbnail()
    }
    func useFile(_ url: URL) { settings.source = .file(url.path) }

    // MARK: render

    /// The picture as uploaded: (1280x720 image, JPEG <= 2 MB). Rendering runs off the main thread.
    func makeImage() async -> (image: CGImage, jpeg: Data)? {
        let source = settings.source
        let scene = scene(for: source)
        let vars = Self.prepare(env.variables())
        let render = env.render
        return await Task.detached(priority: .userInitiated) { () -> (image: CGImage, jpeg: Data)? in
            let raw: CGImage?
            if case .file(let p) = source { raw = ThumbnailImage.load(URL(fileURLWithPath: p)) }
            else if let scene { raw = render(scene, ThumbnailImage.size, vars, 4, nil) }       // time 4, clock nil: entrances done
            else { raw = nil }
            guard let raw, let n = ThumbnailImage.normalized(raw), let jpeg = ThumbnailImage.encode(n) else { return nil }
            return (n, jpeg)
        }.value
    }
    /// Thumbnail-only text tweaks: a title separator dash stays at the end of line 1 ("GRAND FINALS -" / "MATCH 3"),
    /// never starts line 2.
    nonisolated static func prepare(_ v: SceneVariables) -> SceneVariables {
        var v = v
        if let t = v[MatchKeys.matchTitle] {
            var s = t
            for d in [" - ", " – ", " — "] { s = s.replacingOccurrences(of: d, with: "\u{00A0}" + d.dropFirst()) }
            v[MatchKeys.matchTitle] = s
        }
        return v
    }
    func refreshPreview() async {
        rendering = true; defer { rendering = false }
        previewStale = false
        if let r = await makeImage() { preview = r.image; previewBytes = r.jpeg.count; previewError = nil }
        else {
            preview = nil; previewBytes = nil
            if case .file = settings.source { previewError = "Couldn't read that image. Pick a PNG or JPG." } else { previewError = "Couldn't render the thumbnail." }
        }
    }
    /// JPEG for "Save thumbnail…".
    func jpegForSave() async -> Data? { await makeImage()?.jpeg }

    // MARK: upload

    /// Go Live (Admin YouTube) succeeded: upload once when "Set automatically" is on.
    func broadcastStarted(id: String, matchId: String?) {
        guard settings.autoSet else { return }
        autoTask = Task { [weak self] in _ = await self?.upload(broadcastId: id, matchId: matchId) }
    }
    /// "Update thumbnail now" (while live).
    @discardableResult
    func updateNow() async -> ThumbnailReply? {
        guard let id = env.broadcastId() else { return nil }
        return await upload(broadcastId: id, matchId: env.matchId())
    }

    /// Render + upload, retrying 5xx / timeouts up to 3 times with backoff. 501 / 403 / 409 / 413 / 429 are reported, not retried.
    @discardableResult
    func upload(broadcastId: String, matchId: String?) async -> ThumbnailReply? {
        guard !uploading else { return nil }
        uploading = true; defer { uploading = false }
        status = .working("Rendering thumbnail…")
        guard let made = await makeImage() else {
            status = .failed(previewErrorText); return nil
        }
        preview = made.image; previewBytes = made.jpeg.count; previewStale = false
        let u = ThumbnailUpload(broadcastId: broadcastId, matchId: matchId, image: made.jpeg)
        var attempt = 0
        while true {
            status = .working(attempt == 0 ? "Setting thumbnail…" : "Setting thumbnail… (retry \(attempt))")
            let reply = await env.upload(u)
            if reply.isRetryable && attempt < Self.maxRetries {
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(max(0, retryDelay * pow(2, Double(attempt - 1))) * 1_000_000_000))
                if Task.isCancelled { status = .failed(reply.message); return reply }
                continue
            }
            switch reply {
            case .set(let url): status = .set(url: url, at: Date())
            case .unsupported: status = .unsupported
            default: status = .failed(reply.message)
            }
            return reply
        }
    }
    private var previewErrorText: String {
        if case .file = settings.source { return "Couldn't read the thumbnail image. Pick a PNG or JPG." }
        return "Couldn't render the thumbnail."
    }
}
