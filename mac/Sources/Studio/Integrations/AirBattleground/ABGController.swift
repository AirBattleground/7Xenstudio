import Foundation
import Observation

/// Where the picked match is remembered (the active show's `link`).
@MainActor protocol ABGLinkPersistence: AnyObject { var link: ShowLink? { get set } }

@MainActor final class ABGMemoryPersistence: ABGLinkPersistence { var link: ShowLink? }

/// Persists on the active StudioShow in store.json (the link holds no secret).
@MainActor final class ABGStorePersistence: ABGLinkPersistence {
    let store: StudioStore
    init(store: StudioStore) { self.store = store }
    var link: ShowLink? {
        get { store.shows.first { $0.id == store.ensureActiveShow().id }?.link }
        set { let id = store.ensureActiveShow().id; store.update { doc in if let i = doc.shows.firstIndex(where: { $0.id == id }) { doc.shows[i].link = newValue } } }
    }
}

/// What Go Live needs to start streaming to the admin's YouTube.
struct ABGIngest: Equatable {
    var broadcastId: String
    var watchUrl: String?
    var destinations: [Destination]
}

/// Connection, match selection, ingest lookup, heartbeats and end-of-show for the AirBattleground link.
@MainActor @Observable
final class ABGController {
    static let integrationId = "airbattleground"
    /// old: INTEGRATION_HEARTBEAT_MS (shows.ts) and PRESENCE_MS (index.ts)
    nonisolated static let heartbeatSeconds: Double = 10
    nonisolated static let presenceSeconds: Double = 20

    @ObservationIgnored let service: BroadcastLinkService
    @ObservationIgnored private let persistence: ABGLinkPersistence

    private(set) var account: ABGAccount?
    private(set) var host: String?
    var isConnected: Bool { account != nil }
    private(set) var connecting = false
    /// Last failure of any call (old info().error); cleared by the next success.
    private(set) var lastError: String?
    private(set) var link: ShowLink?
    private(set) var matches: [ABGMatch] = []
    private(set) var matchesLoading = false
    private(set) var matchesError: String?
    private(set) var matchesLoadedAt: Date?
    /// set while a broadcast is open on AirBattleground (from Go Live until the show ends)
    private(set) var broadcastId: String?
    private(set) var watchUrl: String?
    private(set) var heartbeatError: String?
    var showConnect = false
    var showMatches = false

    /// called when AirBattleground answers a heartbeat with stop: true
    @ObservationIgnored var onRemoteStop: (() -> Void)?
    @ObservationIgnored var statusProvider: () -> ABGHeartbeat = { ABGHeartbeat(state: "starting", fps: nil, bitrateKbps: nil) }
    @ObservationIgnored var heartbeatInterval: Double = ABGController.heartbeatSeconds
    @ObservationIgnored var retryDelay: Double = 1.0
    @ObservationIgnored private var lastCallAt = Date.distantPast
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var presenceTask: Task<Void, Never>?

    init(service: BroadcastLinkService, persistence: ABGLinkPersistence? = nil, startPresence: Bool = true) {
        self.service = service; self.persistence = persistence ?? ABGMemoryPersistence()
        account = service.account; host = service.host
        link = self.persistence.link
        if startPresence { startPresenceLoop() }
    }
    deinit { heartbeatTask?.cancel(); presenceTask?.cancel() }

    // MARK: derived
    var selectedTitle: String? { link?.eventTitle }
    var hasMatch: Bool { link?.eventId != nil }
    var isBroadcasting: Bool { broadcastId != nil }
    /// "connected" | "error" | "off" for chips
    var chipTitle: String {
        guard isConnected else { return "AirBattleground" }
        return link?.eventTitle ?? "No match"
    }

    private func track<T>(_ body: () async throws -> T) async throws -> T {
        do { let v = try await body(); lastCallAt = Date(); lastError = nil; return v }
        catch { lastError = Self.message(error); throw error }
    }
    nonisolated static func message(_ e: Error) -> String { (e as? ABGError)?.errorDescription ?? "AirBattleground isn't answering." }

    /// retry network failures (never operator errors like a bad key)
    private func retrying<T>(attempts: Int = 3, _ body: () async throws -> T) async throws -> T {
        var n = 0
        while true {
            do { return try await track(body) }
            catch let e as ABGError where e.isTransient && n < attempts - 1 {
                n += 1
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * Double(n) * 1_000_000_000))
                if Task.isCancelled { throw e }
            }
        }
    }

    // MARK: connect
    func connect(link text: String) async throws {
        guard ABGLink.parse(text) != nil else { throw ABGError.invalidLink }
        connecting = true; defer { connecting = false }
        account = try await track { try await service.connect(link: text) }
        host = service.host
        await refreshMatches()
    }
    func disconnect() {
        guard !isBroadcasting else { return }
        service.disconnect()
        account = nil; host = nil; lastError = nil; matches = []; matchesError = nil
    }

    // MARK: matches
    func refreshMatches() async {
        guard isConnected else { return }
        matchesLoading = true; defer { matchesLoading = false }
        do { matches = try await track { try await service.matches() }; matchesError = nil; matchesLoadedAt = Date() }
        catch { matchesError = Self.message(error); noteAuthFailure(error) }
    }
    func select(_ m: ABGMatch) {
        let l = ShowLink(integration: Self.integrationId, eventId: m.id, eventTitle: m.title, eventSubtitle: m.subtitle.isEmpty ? nil : m.subtitle,
                         eventStatus: m.status.rawValue, startsAt: m.startsAt)
        persistence.link = l; link = l
    }
    func clearSelection() { persistence.link = nil; link = nil }

    /// upcoming + live by default, searched by title / subtitle; live first, then by start time
    nonisolated static func filter(_ ms: [ABGMatch], query: String, includeFinished: Bool) -> [ABGMatch] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func rank(_ s: ABGMatch.Status) -> Int { s == .live ? 0 : s == .upcoming ? 1 : 2 }
        return ms.filter { (includeFinished || $0.status != .done) && (q.isEmpty || $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)) }
            .sorted { a, b in rank(a.status) != rank(b.status) ? rank(a.status) < rank(b.status) : (a.startsAt ?? "") < (b.startsAt ?? "") }
    }

    private func noteAuthFailure(_ e: Error) { /* keep the key: the operator decides to reconnect (old behaviour) */ }

    // MARK: presence (AirBattleground shows the studio Online for 30 s after the last call)
    private func startPresenceLoop() {
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                await self.presenceTick()
            }
        }
    }
    func presenceTick(now: Date = Date()) async {
        guard isConnected, now.timeIntervalSince(lastCallAt) >= Self.presenceSeconds - 1 else { return }
        if let a = try? await track({ try await service.me() }), a != account { account = a }
    }

    // MARK: go live
    /// Fresh ingest info right before starting: checks the account's YouTube, opens the broadcast for the picked match.
    func prepareYouTube() async throws -> ABGIngest {
        guard isConnected else { throw ABGError.notConnected }
        guard let l = link, let matchId = l.eventId else { throw ABGError.noMatch }
        let outs = try await retrying { try await service.outputs() }
        guard outs.siteYoutube != nil else { throw ABGError.noYouTube }
        let input = ABGBroadcastInput(matchId: matchId, title: l.eventTitle ?? "Live show", livePage: false, siteYoutube: true, destinationIds: [])
        let b = try await retrying(attempts: 2) { try await service.startBroadcast(input) }
        let dests = b.targets.compactMap { Self.destination(from: $0) }
        guard !dests.isEmpty else {
            try? await track { try await service.stopBroadcast(id: b.id) }
            throw ABGError.noStreamKey
        }
        broadcastId = b.id; watchUrl = b.watchUrl; heartbeatError = nil
        return ABGIngest(broadcastId: b.id, watchUrl: b.watchUrl, destinations: dests)
    }

    /// rtmp://host/app/KEY -> url rtmp://host/app + key KEY. Ids are namespaced so they never clash with saved destinations.
    nonisolated static func destination(from t: ABGBroadcast.Target) -> Destination? {
        let u = t.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard u.lowercased().hasPrefix("rtmp"), !t.id.isEmpty else { return nil }
        let name = "YouTube (AirBattleground)"
        let afterScheme = u.range(of: "://").map { u[$0.upperBound...] } ?? Substring(u)
        let parts = afterScheme.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 3, let slash = u.lastIndex(of: "/") {
            let key = String(u[u.index(after: slash)...]), base = String(u[..<slash])
            if !key.isEmpty { return Destination(id: "abg:\(t.id)", name: name, kind: .youtube, url: base, key: key) }
        }
        return parts.count >= 2 ? Destination(id: "abg:\(t.id)", name: name, kind: .youtube, url: u, key: "") : nil
    }

    /// Go Live failed after the broadcast was opened: close it again.
    func abortBroadcast() async {
        guard let id = broadcastId else { return }
        broadcastId = nil; watchUrl = nil
        try? await track { try await service.stopBroadcast(id: id) }
    }

    func beginHeartbeats() {
        heartbeatTask?.cancel()
        guard let id = broadcastId else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.heartbeatInterval ?? 10) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.sendHeartbeat(id: id)
            }
        }
    }
    func sendHeartbeat(id: String) async {
        let status = statusProvider()
        do {
            let stop = try await track { try await service.heartbeat(id: id, status: status) }
            heartbeatError = nil
            if stop, broadcastId == id { onRemoteStop?() }
        } catch { heartbeatError = Self.message(error) }   // keep trying on the next beat, like the old shows.ts
    }

    /// The show ended (or Go Live was cancelled): stop beating and tell AirBattleground (retried).
    func endBroadcast() async {
        heartbeatTask?.cancel(); heartbeatTask = nil
        guard let id = broadcastId else { return }
        broadcastId = nil; watchUrl = nil
        do { try await retrying(attempts: 3) { try await service.stopBroadcast(id: id) }; heartbeatError = nil }
        catch { heartbeatError = "AirBattleground wasn't told the show ended (\(Self.message(error))). End the broadcast on AirBattleground." }
    }
}
