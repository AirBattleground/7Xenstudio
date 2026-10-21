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
}

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
}

/// Canned data, configurable failures, records calls. Used by previews (STUDIO_ABG_MOCK=1) and tests.
final class MockBroadcastLinkService: BroadcastLinkService, @unchecked Sendable {
    private let lock = NSLock()
    private var _account: ABGAccount?
    var matchList: [ABGMatch] = [
        ABGMatch(id: "m1", title: "Dragons vs Wolves", subtitle: "Grand Final", startsAt: nil, status: .live),
        ABGMatch(id: "m2", title: "Hawks vs Foxes", subtitle: "Semi 1", startsAt: "2026-11-01T18:00:00Z", status: .upcoming),
        ABGMatch(id: "m3", title: "Bears vs Owls", subtitle: "Group A", startsAt: nil, status: .done)]
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
}
