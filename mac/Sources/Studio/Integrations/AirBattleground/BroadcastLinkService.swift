import Foundation

/// What the studio needs from a broadcast platform. `StudioLinkService` talks to AirBattleground;
/// `MockBroadcastLinkService` is for previews and tests.
protocol BroadcastLinkService: Sendable {
    /// Cheap, no network: the signed-in account (from the secret store) or nil.
    var account: ABGAccount? { get }
    var host: String? { get }
    func connect(link: String) async throws -> ABGAccount
    func disconnect()
    func me() async throws -> ABGAccount
    func matches() async throws -> [ABGMatch]
    func outputs() async throws -> ABGOutputs
    func startBroadcast(_ input: ABGBroadcastInput) async throws -> ABGBroadcast
    /// true = AirBattleground asked the studio to end the show
    func heartbeat(id: String, status: ABGHeartbeat) async throws -> Bool
    func stopBroadcast(id: String) async throws
    /// Host + studio key for read-only calls made outside the controller (Team Status board live data).
    var studioLinkCredentials: (host: String, key: String)? { get }
    /// Auto capture: POST a still to the match's screenshots (multipart). Never throws; `.unreachable` covers transport failures.
    func uploadCapture(_ u: CaptureUpload) async -> CaptureReply
    /// Match control: POST …/start | …/stop -> the GET …/live body (raw). Throws .conflict(message) on 409.
    func startMatch(id: String) async throws -> Data
    func stopMatch(id: String) async throws -> Data
    /// Detection result of one screenshot (GET …/captures/{captureId}). Never throws.
    func captureResult(matchId: String, captureId: String) async -> CaptureResultReply
    /// YouTube thumbnail: POST …/broadcasts/{id}/thumbnail (multipart). Never throws; `.unreachable` covers transport failures.
    func uploadThumbnail(_ u: ThumbnailUpload) async -> ThumbnailReply
}
extension BroadcastLinkService { var studioLinkCredentials: (host: String, key: String)? { nil } }

final class StudioLinkService: BroadcastLinkService, @unchecked Sendable {
    private let secrets: ABGSecretStore
    private let session: URLSession
    private let lock = NSLock()
    private var creds: ABGCredentials?

    init(secrets: ABGSecretStore = ABGKeychainStore(), session: URLSession = .shared) {
        self.secrets = secrets; self.session = session; creds = secrets.load()
    }
    var account: ABGAccount? { lock.withLock { creds?.account } }
    var host: String? { lock.withLock { creds?.host } }
    var studioLinkCredentials: (host: String, key: String)? { lock.withLock { creds.map { ($0.host, $0.key) } } }
    private func client() throws -> StudioLinkClient {
        guard let c = lock.withLock({ creds }) else { throw ABGError.notConnected }
        return StudioLinkClient(host: c.host, key: c.key, session: session)
    }

    func connect(link: String) async throws -> ABGAccount {
        guard let p = ABGLink.parse(link) else { throw ABGError.invalidLink }
        let acct = try await StudioLinkClient(host: p.host, key: p.key, session: session).me().account
        let c = ABGCredentials(host: p.host, key: p.key, account: acct)
        try secrets.save(c)
        lock.withLock { creds = c }
        return acct
    }
    func disconnect() { secrets.clear(); lock.withLock { creds = nil } }
    func me() async throws -> ABGAccount {
        let c = try client(); let a = try await c.me().account
        lock.withLock { if var cur = creds, cur.key == c.key, cur.account != a { cur.account = a; creds = cur; try? secrets.save(cur) } }
        return a
    }
    func matches() async throws -> [ABGMatch] { try await client().matches() }
    func outputs() async throws -> ABGOutputs { try await client().outputs() }
    func startBroadcast(_ i: ABGBroadcastInput) async throws -> ABGBroadcast { try await client().startBroadcast(i) }
    func heartbeat(id: String, status: ABGHeartbeat) async throws -> Bool { try await client().heartbeat(id: id, status: status) }
    func stopBroadcast(id: String) async throws { try await client().stopBroadcast(id: id) }
    func uploadCapture(_ u: CaptureUpload) async -> CaptureReply {
        guard let c = try? client() else { return .keyRejected }
        return await c.uploadCapture(u)
    }
    func startMatch(id: String) async throws -> Data { try await client().startMatch(id) }
    func stopMatch(id: String) async throws -> Data { try await client().stopMatch(id) }
    func captureResult(matchId: String, captureId: String) async -> CaptureResultReply {
        guard let c = try? client() else { return .failed(ABGError.notConnected.errorDescription ?? "") }
        return await c.captureResult(matchId: matchId, captureId: captureId)
    }
    func uploadThumbnail(_ u: ThumbnailUpload) async -> ThumbnailReply {
        guard let c = try? client() else { return .keyRejected }
        return await c.uploadThumbnail(u)
    }
}

/// Canned data, configurable failures, records calls. Used by previews (STUDIO_ABG_MOCK=1) and tests.
final class MockBroadcastLinkService: BroadcastLinkService, @unchecked Sendable {
    private let lock = NSLock()
    private var _account: ABGAccount?
    var matchList: [ABGMatch] = [
        ABGMatch(id: "m1", title: "Dragons vs Wolves", subtitle: "Grand Final", startsAt: nil, status: .live),
        ABGMatch(id: "m2", title: "Hawks vs Foxes", subtitle: "Semi 1", startsAt: "2026-11-01T18:00:00Z", status: .upcoming),
        ABGMatch(id: "m3", title: "Bears vs Owls", subtitle: "Group A", startsAt: nil, status: .done)]
    /// STUDIO_ABG_MOCK=1 previews: matches with the new control block (locked with a countdown, ready, live, published)
    static func controlDemoMatches(now: Date = Date()) -> [ABGMatch] {
        let f = ISO8601DateFormatter()
        return [
            ABGMatch(id: "c1", title: "Match 1", subtitle: "Scrim · Erangel", startsAt: f.string(from: now.addingTimeInterval(900)), status: .upcoming,
                     control: MatchControl(state: .locked, unlocksAt: f.string(from: now.addingTimeInterval(120)),
                                           reason: "Registration is open until 10:30 PM (12/16 slots filled)", teams: 12, slots: 16)),
            ABGMatch(id: "c2", title: "Match 2", subtitle: "Scrim · Miramar", startsAt: nil, status: .upcoming,
                     control: MatchControl(state: .ready, reason: "All 16 slots filled", teams: 16, slots: 16)),
            ABGMatch(id: "c3", title: "Match 3", subtitle: "Scrim · Sanhok", startsAt: nil, status: .live, control: MatchControl(state: .live, teams: 16, slots: 16)),
            ABGMatch(id: "c4", title: "Match 0", subtitle: "Scrim · Vikendi", startsAt: nil, status: .done, control: MatchControl(state: .published, teams: 16, slots: 16))]
    }
    var outputsResult = ABGOutputs(livePage: true, siteYoutube: .init(channelTitle: "AirBattleground"), destinations: [])
    var broadcastResult = ABGBroadcast(id: "b1", targets: [.init(id: "yt", name: "YouTube", url: "rtmp://a.rtmp.youtube.com/live2/mock-stream-key")], watchUrl: "https://youtu.be/mock")
    var stopOnHeartbeat = false
    /// thrown by every call when set
    var failure: ABGError?
    /// thrown by startBroadcast this many times, then succeeds
    var startFailures = 0
    private(set) var calls: [String] = []
    private(set) var heartbeats: [ABGHeartbeat] = []
    private(set) var startedInputs: [ABGBroadcastInput] = []

    init(account: ABGAccount? = nil) { _account = account }
    var account: ABGAccount? { lock.withLock { _account } }
    var host: String? { account == nil ? nil : abgDefaultHost }
    private func note(_ s: String) throws { if let f = lock.withLock({ calls.append(s); return failure }) { throw f } }
    func connect(link: String) async throws -> ABGAccount {
        try note("connect")
        guard ABGLink.parse(link) != nil else { throw ABGError.invalidLink }
        let a = ABGAccount(name: "Mock Admin", org: "Mock Org"); lock.withLock { _account = a }; return a
    }
    func disconnect() { lock.withLock { _account = nil; calls.append("disconnect") } }
    func me() async throws -> ABGAccount { try note("me"); guard let a = account else { throw ABGError.notConnected }; return a }
    func matches() async throws -> [ABGMatch] { try note("matches"); return matchList }
    func outputs() async throws -> ABGOutputs { try note("outputs"); return outputsResult }
    func startBroadcast(_ i: ABGBroadcastInput) async throws -> ABGBroadcast {
        try note("start")
        let fail = lock.withLock { () -> Bool in startedInputs.append(i); let f = startFailures > 0; if f { startFailures -= 1 }; return f }
        if fail { throw ABGError.unreachable }
        return broadcastResult
    }
    func heartbeat(id: String, status: ABGHeartbeat) async throws -> Bool {
        try note("heartbeat"); lock.withLock { heartbeats.append(status) }; return stopOnHeartbeat
    }
    func stopBroadcast(id: String) async throws { try note("stop:\(id)") }

    /// Auto capture: every upload is recorded; replies come from `captureReplies` (first in, first out), then `captureReply`.
    var captureReply: CaptureReply = .accepted(captureId: nil, queuePosition: 1, nextIntervalSeconds: nil)
    var captureReplies: [CaptureReply] = []
    /// simulated upload time (seconds), for in-flight tests
    var captureDelay: Double = 0
    private var _uploads: [CaptureUpload] = []
    var uploads: [CaptureUpload] { lock.withLock { _uploads } }
    func uploadCapture(_ u: CaptureUpload) async -> CaptureReply {
        let d = lock.withLock { calls.append("capture:\(u.kind?.rawValue ?? "-")"); _uploads.append(u); return captureDelay }
        if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000)) }
        return lock.withLock { captureReplies.isEmpty ? captureReply : captureReplies.removeFirst() }
    }

    /// Match control: start/stop move the match's control state (409 like the server when not allowed); records "startMatch:id".
    var controlConflict: String?
    func startMatch(id: String) async throws -> Data { try note("startMatch:\(id)"); return try transition(id, from: [.ready], to: .live, verb: "start") }
    func stopMatch(id: String) async throws -> Data { try note("stopMatch:\(id)"); return try transition(id, from: [.live], to: .ended, verb: "stop") }
    private func transition(_ id: String, from: Set<MatchControl.State>, to: MatchControl.State, verb: String) throws -> Data {
        if let m = lock.withLock({ controlConflict }) { throw ABGError.conflict(m) }
        let state: MatchControl.State = try lock.withLock {
            guard let i = matchList.firstIndex(where: { $0.id == id }) else { throw ABGError.matchNotFound(nil) }
            let cur = matchList[i].control
            if let cur, !from.contains(cur.state) { throw ABGError.conflict("Can't \(verb) \(matchList[i].title): it is \(cur.state.rawValue).") }
            var c = cur ?? MatchControl(state: to); c.state = to; c.unlocksAt = nil
            matchList[i].control = c; matchList[i].status = to == .live ? .live : .done
            return to
        }
        return Data(#"{"match":{"id":"\#(id)","state":"\#(state == .live ? "live" : "summary")"},"control":{"state":"\#(state.rawValue)"},"autoCapture":{"active":true,"paused":false}}"#.utf8)
    }
    /// Detection results: `captureResults` first in, first out, then `captureResultReply`.
    var captureResultReply: CaptureResultReply = .result(CaptureResult(status: .applied, detected: "lobby", confidence: 0.97, message: "Read 14 teams from the lobby"))
    var captureResults: [CaptureResultReply] = []
    func captureResult(matchId: String, captureId: String) async -> CaptureResultReply {
        lock.withLock { calls.append("captureResult:\(captureId)"); return captureResults.isEmpty ? captureResultReply : captureResults.removeFirst() }
    }

    /// YouTube thumbnail: every upload is recorded ("thumbnail:broadcastId"); replies from `thumbnailReplies` (FIFO), then `thumbnailReply`.
    var thumbnailReply: ThumbnailReply = .set(url: "https://i.ytimg.com/vi/mock/maxresdefault.jpg")
    var thumbnailReplies: [ThumbnailReply] = []
    private var _thumbnails: [ThumbnailUpload] = []
    var thumbnails: [ThumbnailUpload] { lock.withLock { _thumbnails } }
    func uploadThumbnail(_ u: ThumbnailUpload) async -> ThumbnailReply {
        lock.withLock {
            calls.append("thumbnail:\(u.broadcastId)"); _thumbnails.append(u)
            return thumbnailReplies.isEmpty ? thumbnailReply : thumbnailReplies.removeFirst()
        }
    }
}
