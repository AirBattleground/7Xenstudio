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

    // MARK: match control (state from the server only)
    /// control of the picked match from the newest server answer (match list, GET …/live, start / stop)
    private(set) var liveControl: MatchControl?
    /// autoCapture block of GET …/live for the picked match
    private(set) var liveAutoCapture: LiveAutoCapture?
    private(set) var liveUpdatedAt: Date?
    /// Start / Stop in progress
    private(set) var controlBusy = false
    /// 409 (or other) message of the last Start / Stop; cleared by the next success
    private(set) var controlMessage: String?
    /// set by a successful Stop: prompt "Send the results screenshot(s)" (also shown whenever the state is `ended`)
    private(set) var stoppedAt: Date?
    /// the start / stop answer (same body as GET …/live): handed to the shared match data store so scenes update at once
    @ObservationIgnored var onLiveBody: ((Data) -> Void)?
    /// list poll period while a match is picked or the picker is open
    @ObservationIgnored var listPollSeconds: Double = 30

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
        if startPresence { startPresenceLoop(); startListPolling() }
    }
    deinit { heartbeatTask?.cancel(); presenceTask?.cancel(); listTask?.cancel() }
    @ObservationIgnored private var listTask: Task<Void, Never>?

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
        do {
            matches = try await track { try await service.matches() }; matchesError = nil; matchesLoadedAt = Date()
            if let m = selectedMatch, let c = m.control { liveControl = c }
        }
        catch { matchesError = Self.message(error); noteAuthFailure(error) }
    }
    func select(_ m: ABGMatch) {
        let l = ShowLink(integration: Self.integrationId, eventId: m.id, eventTitle: m.title, eventSubtitle: m.subtitle.isEmpty ? nil : m.subtitle,
                         eventStatus: m.status.rawValue, startsAt: m.startsAt)
        if l.eventId != link?.eventId { resetControl() }
        liveControl = m.control
        persistence.link = l; link = l
    }
    func clearSelection() { persistence.link = nil; link = nil; resetControl() }
    private func resetControl() { liveControl = nil; liveAutoCapture = nil; liveUpdatedAt = nil; controlMessage = nil; stoppedAt = nil }

    // MARK: match control

    /// The picked match as last listed.
    var selectedMatch: ABGMatch? { link?.eventId.flatMap { id in matches.first { $0.id == id } } }
    /// control.state etc. of the picked match (nil = legacy server without control: allow everything).
    var selectedControl: MatchControl? { liveControl ?? selectedMatch?.control }
    var controlButton: MatchControlButton {
        MatchControlButton.make(selectedControl, legacyStatus: selectedMatch?.status ?? link?.eventStatus.flatMap(ABGMatch.Status.init(rawValue:)))
    }
    /// "Send the results screenshot(s)" prompt: after Stop, until the manager publishes
    var awaitingResults: Bool {
        if let c = selectedControl { return c.state == .ended }
        return stoppedAt != nil
    }

    func startMatch() async { await control(start: true) }
    func stopMatch() async { await control(start: false) }
    private func control(start: Bool) async {
        guard let id = link?.eventId, !controlBusy else { return }
        controlBusy = true; defer { controlBusy = false }
        do {
            let body = try await track { try await (start ? service.startMatch(id: id) : service.stopMatch(id: id)) }
            controlMessage = nil
            if !start { stoppedAt = Date() }
            ingestLive(body, matchId: id)
            onLiveBody?(body)
            if let c = liveControl, let i = matches.firstIndex(where: { $0.id == id }) { matches[i].control = c }
        } catch {
            // keep the button driven by control.state; show the server's words
            controlMessage = Self.message(error)
            if case ABGError.conflict = error { Task { await self.refreshMatches() } }
        }
    }

    /// A GET …/live (or start / stop) body for the picked match: control + autoCapture blocks. Ignored when it belongs to another match.
    func ingestLive(_ data: Data, matchId: String? = nil, now: Date = Date()) {
        guard let b = LiveControlBody.parse(data) else { return }
        guard let picked = link?.eventId else { return }
        if let m = b.matchId ?? matchId, m != picked { return }
        if let c = b.control { liveControl = c }
        if let a = b.autoCapture { liveAutoCapture = a }
        liveUpdatedAt = now
    }

    /// Re-list every 30 s while a match is picked (or the picker is open), and once when a locked countdown reaches 0.
    func listRefreshDue(now: Date) -> Bool {
        guard isConnected, !matchesLoading else { return false }
        let last = matchesLoadedAt ?? .distantPast
        if (hasMatch || showMatches) && now.timeIntervalSince(last) >= listPollSeconds { return true }
        let unlocks = matches.compactMap { $0.control?.state == .locked ? $0.control?.unlocksAtDate : nil }
            + [liveControl?.state == .locked ? liveControl?.unlocksAtDate : nil].compactMap { $0 }
        return unlocks.contains { $0 <= now && $0 > last }
    }
    func startListPolling() {
        guard listTask == nil else { return }
        listTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.listRefreshDue(now: Date()) { await self.refreshMatches() }
            }
        }
    }

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
