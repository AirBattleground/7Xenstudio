import Testing
import Foundation
@testable import Studio

// MARK: URLProtocol stub: replays AirBattleground's studio-link responses; routes by host so suites can run in parallel.

final class ABGStub: URLProtocol, @unchecked Sendable {
    struct Seen { var method: String, path: String, key: String?, body: Data?, accept: String?, contentType: String? }
    typealias Handler = @Sendable (Seen) -> (status: Int, body: String)?
    nonisolated(unsafe) static var routes: [String: Handler] = [:]
    nonisolated(unsafe) static var seen: [String: [Seen]] = [:]
    static let lock = NSLock()

    static func session(host: String, _ h: @escaping Handler) -> URLSession {
        lock.withLock { routes[host] = h; seen[host] = [] }
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [ABGStub.self]
        return URLSession(configuration: c)
    }
    static func requests(_ host: String) -> [Seen] { lock.withLock { seen[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        let req = request
        var body = req.httpBody
        if body == nil, let st = req.httpBodyStream {
            st.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while st.hasBytesAvailable { let n = st.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            st.close(); body = d
        }
        let host = req.url?.host ?? ""
        let seen = Seen(method: req.httpMethod ?? "", path: req.url?.path ?? "", key: req.value(forHTTPHeaderField: "X-Studio-Key"), body: body,
                        accept: req.value(forHTTPHeaderField: "Accept"), contentType: req.value(forHTTPHeaderField: "Content-Type"))
        let h = Self.lock.withLock { () -> Handler? in Self.seen[host, default: []].append(seen); return Self.routes[host] }
        guard let r = h?(seen) else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        let resp = HTTPURLResponse(url: req.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(r.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func json(_ d: Data?) -> [String: Any] { (d.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
private let goodKey = "sw_abcdefgh12345678"

// MARK: link parsing (port of link.ts)

@Suite struct ABGLinkTests {
    @Test func bareKeyUsesDefaultHost() {
        #expect(ABGLink.parse(goodKey) == ABGConnectLink(host: "https://airbattleground.com", key: goodKey))
        #expect(ABGLink.parse("  \(goodKey)\n")?.key == goodKey)
        #expect(ABGLink.parse("sw_short") == nil)
        #expect(ABGLink.parse("xx_abcdefgh12345678") == nil)
    }
    @Test func customSchemeAndHttpsForms() {
        #expect(ABGLink.parse("7xen-studio://connect?host=https://example.org&key=\(goodKey)") == ABGConnectLink(host: "https://example.org", key: goodKey))
        #expect(ABGLink.parse("7XEN-STUDIO://connect/?key=\(goodKey)")?.host == "https://airbattleground.com")
        #expect(ABGLink.parse("7xen-studio://connect?host=ftp://x&key=\(goodKey)") == nil)
        #expect(ABGLink.parse("https://abg.example.com:8443/studio?key=\(goodKey)") == ABGConnectLink(host: "https://abg.example.com:8443", key: goodKey))
        #expect(ABGLink.parse("https://abg.example.com/studio") == nil)
        #expect(ABGLink.parse("hello") == nil)
    }
    @Test func masking() { #expect(ABGLink.mask("sw_abcdefgh12345678") == "sw_abcd…5678"); #expect(ABGLink.mask("sw_abc") == "sw_abc") }
}

// MARK: client request / response shapes (client.ts)

@Suite struct ABGClientTests {
    @Test func meSendsKeyHeaderAndDecodes() async throws {
        let host = "me.abg.test"
        let s = ABGStub.session(host: host) { _ in (200, #"{"manager":{"name":"Rita"},"org":{"name":"Air Org"}}"#) }
        let me = try await StudioLinkClient(host: "https://\(host)", key: goodKey, session: s).me()
        #expect(me.account == ABGAccount(name: "Rita", org: "Air Org"))
        let r = try #require(ABGStub.requests(host).first)
        #expect(r.method == "GET" && r.path == "/api/studio-link/me" && r.key == goodKey && r.accept == "application/json")
    }
    @Test func matchesDecodeNumericIdsAndMissingFields() async throws {
        let host = "matches.abg.test"
        let s = ABGStub.session(host: host) { _ in (200, #"{"items":[{"id":7,"title":"A vs B","subtitle":"Final","startsAt":"2026-11-01T18:00:00Z","status":"live"},{"id":"x","title":"C vs D","status":"upcoming"}]}"#) }
        let ms = try await StudioLinkClient(host: "https://\(host)", key: goodKey, session: s).matches()
        #expect(ms.map(\.id) == ["7", "x"] && ms[0].status == .live && ms[1].subtitle == "" && ms[1].startsAt == nil)
        #expect(ABGStub.requests(host).first?.path == "/api/studio-link/matches")
    }
    @Test func outputsAndStartBroadcastBody() async throws {
        let host = "bc.abg.test"
        let s = ABGStub.session(host: host) { r in
            r.path.hasSuffix("/outputs") ? (200, #"{"livePage":true,"siteYoutube":{"channelTitle":"ABG TV"},"destinations":[{"id":"d1","name":"Twitch","kind":"rtmp"}]}"#)
            : (200, #"{"id":42,"targets":[{"id":"yt","name":"YouTube","url":"rtmp://a.rtmp.youtube.com/live2/abcd-efgh"}],"watchUrl":"https://youtu.be/zz"}"#)
        }
        let c = StudioLinkClient(host: "https://\(host)", key: goodKey, session: s)
        let o = try await c.outputs()
        #expect(o.siteYoutube?.channelTitle == "ABG TV" && o.destinations.first?.id == "d1")
        let b = try await c.startBroadcast(ABGBroadcastInput(matchId: "m9", title: "Final", livePage: false, siteYoutube: true, destinationIds: []))
        #expect(b.id == "42" && b.targets.first?.url.hasSuffix("abcd-efgh") == true && b.watchUrl == "https://youtu.be/zz")
        let post = try #require(ABGStub.requests(host).last)
        #expect(post.method == "POST" && post.path == "/api/studio-link/broadcasts" && post.contentType == "application/json")
        let body = json(post.body)
        #expect(body["matchId"] as? String == "m9" && body["title"] as? String == "Final" && body["livePage"] as? Bool == false
                && body["siteYoutube"] as? Bool == true && (body["destinationIds"] as? [Any])?.isEmpty == true)
    }
    @Test func nullMatchIdIsSentExplicitly() async throws {
        let host = "null.abg.test"
        let s = ABGStub.session(host: host) { _ in (200, #"{"id":"1","targets":[]}"#) }
        _ = try await StudioLinkClient(host: "https://\(host)", key: goodKey, session: s).startBroadcast(ABGBroadcastInput(matchId: nil, title: "t", livePage: true, siteYoutube: false, destinationIds: ["a"]))
        let raw = String(data: try #require(ABGStub.requests(host).first?.body), encoding: .utf8) ?? ""
        #expect(raw.contains(#""matchId":null"#))
    }
    @Test func heartbeatAndStopPaths() async throws {
        let host = "hb.abg.test"
        let s = ABGStub.session(host: host) { r in r.path.hasSuffix("/stop") ? (204, "") : (200, #"{"stop":true}"#) }
        let c = StudioLinkClient(host: "https://\(host)", key: goodKey, session: s)
        let stop = try await c.heartbeat(id: "a/b c", status: ABGHeartbeat(state: "live", fps: 59.9, bitrateKbps: nil))
        #expect(stop)
        try await c.stopBroadcast(id: "a/b c")
        let reqs = ABGStub.requests(host)
        #expect(reqs[0].path == "/api/studio-link/broadcasts/a/b c/heartbeat" || reqs[0].path.contains("heartbeat"))
        #expect(reqs[1].method == "POST" && reqs[1].path.hasSuffix("/stop") && reqs[1].body == nil)
        let b = json(reqs[0].body)
        #expect(b["state"] as? String == "live" && b["fps"] as? Double == 59.9 && b["bitrateKbps"] is NSNull)
        #expect(StudioLinkClient.encodeComponent("a/b c") == "a%2Fb%20c")
    }
    @Test func errorMapping() async throws {
        func run(_ host: String, _ status: Int, _ body: String) async -> ABGError? {
            let s = ABGStub.session(host: host) { _ in (status, body) }
            do { _ = try await StudioLinkClient(host: "https://\(host)", key: goodKey, session: s).me(); return nil } catch { return error as? ABGError }
        }
        #expect(await run("e401.abg.test", 401, "{}") == .keyInvalid)
        #expect(await run("e403.abg.test", 403, "{}") == .keyInvalid)
        #expect(await run("e500.abg.test", 500, "oops") == .http(500))
        #expect(await run("e422.abg.test", 422, #"{"error":{"message":"Match not found"}}"#) == .api("Match not found"))
        #expect(await run("ebad.abg.test", 200, "<html>") == .badResponse)
        let unreachable = StudioLinkClient(host: "https://down.abg.test", key: goodKey, session: ABGStub.session(host: "other.abg.test") { _ in nil })
        do { _ = try await unreachable.me(); Issue.record("expected failure") } catch { #expect(error as? ABGError == .unreachable) }
        #expect(ABGError.keyInvalid.errorDescription == "AirBattleground didn't accept this studio's key. Connect again with a new QR code.")
        #expect(ABGError.unreachable.isTransient && !ABGError.keyInvalid.isTransient && ABGError.http(503).isTransient)
    }
}

// MARK: service + secret store

@Suite struct ABGServiceTests {
    @Test func connectStoresCredentialsInSecretStoreOnly() async throws {
        let host = "svc.abg.test"
        let s = ABGStub.session(host: host) { _ in (200, #"{"manager":{"name":"Rita"},"org":null}"#) }
        let secrets = ABGMemorySecretStore()
        let svc = StudioLinkService(secrets: secrets, session: s)
        #expect(svc.account == nil)
        let a = try await svc.connect(link: "7xen-studio://connect?host=https://\(host)&key=\(goodKey)")
        #expect(a.name == "Rita" && a.org == nil && svc.host == "https://\(host)")
        #expect(secrets.load()?.key == goodKey)
        #expect(StudioLinkService(secrets: secrets, session: s).account?.name == "Rita")   // survives relaunch
        svc.disconnect()
        #expect(secrets.load() == nil && svc.account == nil)
        await #expect(throws: ABGError.notConnected) { _ = try await svc.matches() }
        await #expect(throws: ABGError.invalidLink) { _ = try await svc.connect(link: "nope") }
    }
    @Test func rejectedKeyDoesNotConnect() async throws {
        let host = "rej.abg.test"
        let s = ABGStub.session(host: host) { _ in (401, "{}") }
        let secrets = ABGMemorySecretStore()
        let svc = StudioLinkService(secrets: secrets, session: s)
        await #expect(throws: ABGError.keyInvalid) { _ = try await svc.connect(link: "https://\(host)/x?key=\(goodKey)") }
        #expect(secrets.load() == nil)
    }
    @Test @MainActor func keyNeverReachesStoreJson() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abg-store-\(UUID().uuidString)")
        let store = try StudioStore(dir: dir)
        let mock = MockBroadcastLinkService(account: ABGAccount(name: "A", org: nil))
        let c = ABGController(service: mock, persistence: ABGStorePersistence(store: store), startPresence: false)
        c.select(ABGMatch(id: "m1", title: "Dragons vs Wolves", subtitle: "Final", startsAt: nil, status: .live))
        let json = try String(contentsOf: dir.appendingPathComponent("store.json"), encoding: .utf8)
        #expect(json.contains("Dragons vs Wolves") && !json.contains("sw_"))
        // persisted: a fresh controller on a reopened store sees the link
        let store2 = try StudioStore(dir: dir)
        let c2 = ABGController(service: mock, persistence: ABGStorePersistence(store: store2), startPresence: false)
        #expect(c2.link?.eventId == "m1" && c2.link?.eventSubtitle == "Final")
    }
}

// MARK: controller (match selection, ingest, heartbeats, end of show)

@Suite @MainActor struct ABGControllerTests {
    func make(_ mock: MockBroadcastLinkService = MockBroadcastLinkService(account: ABGAccount(name: "A", org: nil))) -> (ABGController, MockBroadcastLinkService) {
        let c = ABGController(service: mock, startPresence: false); c.retryDelay = 0; c.heartbeatInterval = 0.02; return (c, mock)
    }
    @Test func matchFilterSearchAndOrder() {
        let ms = MockBroadcastLinkService().matchList
        #expect(ABGController.filter(ms, query: "", includeFinished: false).map(\.id) == ["m1", "m2"])
        #expect(ABGController.filter(ms, query: "", includeFinished: true).map(\.id) == ["m1", "m2", "m3"])
        #expect(ABGController.filter(ms, query: "semi", includeFinished: false).map(\.id) == ["m2"])
        #expect(ABGController.filter(ms, query: "WOLVES", includeFinished: false).map(\.id) == ["m1"])
    }
    @Test func refreshAndSelect() async {
        let (c, _) = make()
        await c.refreshMatches()
        #expect(c.matches.count == 3 && c.matchesError == nil)
        c.select(c.matches[1])
        #expect(c.hasMatch && c.link?.eventTitle == "Hawks vs Foxes" && c.link?.integration == "airbattleground")
        c.clearSelection(); #expect(!c.hasMatch)
    }
    @Test func youTubeNeedsMatchAndChannel() async {
        let (c, mock) = make()
        await #expect(throws: ABGError.noMatch) { _ = try await c.prepareYouTube() }
        c.select(MockBroadcastLinkService().matchList[0])
        mock.outputsResult = ABGOutputs(livePage: true, siteYoutube: nil)
        await #expect(throws: ABGError.noYouTube) { _ = try await c.prepareYouTube() }
        let (d, _) = ABGControllerTests().make(MockBroadcastLinkService())
        await #expect(throws: ABGError.notConnected) { _ = try await d.prepareYouTube() }
    }
    @Test func prepareBuildsYouTubeDestinationWithoutLeakingKey() async throws {
        let (c, mock) = make()
        c.select(mock.matchList[0])
        let ingest = try await c.prepareYouTube()
        let d = try #require(ingest.destinations.first)
        #expect(d.url == "rtmp://a.rtmp.youtube.com/live2" && d.key == "mock-stream-key" && d.kind == .youtube && d.id == "abg:yt")
        #expect(redactKeys("ffmpeg -f flv \(d.url)/\(d.key)").contains("mock-stream-key") == false)
        let sent = try #require(mock.startedInputs.first)
        #expect(sent.matchId == "m1" && sent.siteYoutube && !sent.livePage && sent.destinationIds.isEmpty && sent.title == "Dragons vs Wolves")
        #expect(c.broadcastId == "b1" && ingest.watchUrl == "https://youtu.be/mock")
    }
    @Test func noStreamKeyClosesTheBroadcast() async {
        let (c, mock) = make()
        c.select(mock.matchList[0]); mock.broadcastResult = ABGBroadcast(id: "b7", targets: [], watchUrl: nil)
        await #expect(throws: ABGError.noStreamKey) { _ = try await c.prepareYouTube() }
        #expect(mock.calls.contains("stop:b7") && c.broadcastId == nil)
    }
    @Test func networkBlipsAreRetriedButKeyErrorsAreNot() async throws {
        let (c, mock) = make()
        c.select(mock.matchList[0]); mock.startFailures = 1
        _ = try await c.prepareYouTube()
        #expect(mock.calls.filter { $0 == "start" }.count == 2)
        let (c2, m2) = make(); c2.select(m2.matchList[0]); m2.failure = .keyInvalid
        await #expect(throws: ABGError.keyInvalid) { _ = try await c2.prepareYouTube() }
        #expect(m2.calls.filter { $0 == "outputs" }.count == 1 && c2.lastError?.contains("didn't accept") == true)
    }
    @Test func heartbeatsCarryStatusAndRemoteStopEndsShow() async throws {
        let (c, mock) = make()
        c.select(mock.matchList[0])
        c.statusProvider = { ABGHeartbeat(state: "live", fps: 60, bitrateKbps: 11800) }
        var stopped = false; c.onRemoteStop = { stopped = true }
        _ = try await c.prepareYouTube()
        c.beginHeartbeats()
        for _ in 0..<40 where mock.heartbeats.count < 2 { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(mock.heartbeats.count >= 2 && mock.heartbeats[0] == ABGHeartbeat(state: "live", fps: 60, bitrateKbps: 11800) && !stopped)
        mock.stopOnHeartbeat = true
        for _ in 0..<40 where !stopped { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(stopped)
        await c.endBroadcast()
        #expect(mock.calls.contains("stop:b1") && c.broadcastId == nil)
        let n = mock.heartbeats.count
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(mock.heartbeats.count == n)   // heartbeat loop stopped
    }
    @Test func heartbeatFailuresAreShownAndRecover() async throws {
        let (c, mock) = make()
        c.select(mock.matchList[0]); _ = try await c.prepareYouTube()
        mock.failure = .unreachable
        await c.sendHeartbeat(id: "b1")
        #expect(c.heartbeatError == ABGError.unreachable.errorDescription)
        mock.failure = nil
        await c.sendHeartbeat(id: "b1")
        #expect(c.heartbeatError == nil)
    }
    @Test func abortAndDisconnectGuard() async throws {
        let (c, mock) = make()
        c.select(mock.matchList[0]); _ = try await c.prepareYouTube()
        c.disconnect(); #expect(c.isConnected)     // not while a broadcast is open
        await c.abortBroadcast()
        #expect(mock.calls.contains("stop:b1"))
        c.disconnect(); #expect(!c.isConnected && mock.calls.contains("disconnect"))
    }
    @Test func connectThroughController() async throws {
        let (c, _) = make(MockBroadcastLinkService())
        #expect(!c.isConnected)
        await #expect(throws: ABGError.invalidLink) { try await c.connect(link: "garbage") }
        try await c.connect(link: goodKey)
        #expect(c.isConnected && c.account?.name == "Mock Admin" && c.matches.count == 3)
    }
    @Test func destinationSplitting() {
        func d(_ u: String) -> Destination? { ABGController.destination(from: .init(id: "t", name: "n", url: u)) }
        #expect(d("rtmps://a.example.com:443/app/KEY123")?.url == "rtmps://a.example.com:443/app")
        #expect(d("rtmps://a.example.com:443/app/KEY123")?.key == "KEY123")
        #expect(d("rtmp://host/app")?.key == "" && d("rtmp://host/app")?.url == "rtmp://host/app")
        #expect(d("https://nope/x/y") == nil && d("rtmp://host") == nil)
    }
}

// MARK: - match control (new contract)

@Suite struct ControlDecodingTests {
    @Test func listItemsWithAndWithoutControl() async throws {
        let host = "ctl-list.abg.test"
        let body = #"""
        {"items":[
          {"id":"m1","title":"Match 1","subtitle":"Scrim","startsAt":"2026-10-23T17:00:00Z","status":"upcoming",
           "control":{"state":"locked","unlocksAt":"2026-10-23T17:00:00.000Z","reason":"Registration is open until 10:30 PM (12/16 slots filled)","teams":12,"slots":"16"}},
          {"id":"m2","title":"Match 2","status":"live","control":{"state":"LIVE","unlocksAt":null}},
          {"id":"m3","title":"Match 3","status":"upcoming"},
          {"id":"m4","title":"Match 4","status":"upcoming","control":{"state":"paused-by-aliens"}},
          {"id":"m5","title":"Match 5","status":"done","control":null}
        ]}
        """#
        let s = ABGStub.session(host: host) { _ in (200, body) }
        let ms = try await StudioLinkClient(host: "https://\(host)", key: goodKey, session: s).matches()
        #expect(ms.count == 5)
        let c = try #require(ms[0].control)
        #expect(c.state == .locked && c.reason?.hasPrefix("Registration is open") == true && c.teams == 12 && c.slots == 16 && c.teamsLine == "12/16 teams")
        #expect(c.unlocksAtDate == ISO8601DateFormatter().date(from: "2026-10-23T17:00:00Z"))
        #expect(ms[1].control == MatchControl(state: .live))
        #expect(ms[2].control == nil && ms[3].control == nil && ms[4].control == nil)   // absent / unknown -> legacy
    }
    @Test func chipsAndCountdown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let f = ISO8601DateFormatter()
        let locked = MatchControl(state: .locked, unlocksAt: f.string(from: now.addingTimeInterval(751)))
        #expect(locked.chip(now: now) == "Locked · unlocks in 12:31" && locked.secondsToUnlock(now: now) == 751)
        #expect(locked.chip(now: now.addingTimeInterval(800)) == "Locked · unlocking…")
        #expect(MatchControl(state: .locked, unlocksAt: f.string(from: now.addingTimeInterval(4000))).chip(now: now) == "Locked · unlocks in 1:06:40")
        #expect(MatchControl(state: .locked).chip(now: now) == "Locked")
        #expect(MatchControl(state: .ready).chip(now: now) == "Ready" && MatchControl(state: .live).chip(now: now) == "Live")
        #expect(MatchControl(state: .ended).chip(now: now) == "Ended" && MatchControl(state: .published).chip(now: now) == "Published")
        #expect(MatchControl(state: .ready, unlocksAt: f.string(from: now)).secondsToUnlock(now: now) == nil)
    }
    @Test func liveBodyBlocks() {
        let json = #"{"version":3,"match":{"id":"m1","state":"live"},"control":{"state":"live"},"autoCapture":{"active":true,"lastCaptureAt":"2026-10-23T14:05:12.123Z","lastAppliedAt":"2026-10-23T14:05:10Z","lastError":"Frame too dark","paused":true,"lastDetected":"IN_GAME"}}"#
        let b = LiveControlBody.parse(Data(json.utf8))
        #expect(b?.matchId == "m1" && b?.control == MatchControl(state: .live))
        let a = b?.autoCapture
        #expect(a?.active == true && a?.paused == true && a?.lastError == "Frame too dark" && a?.lastDetected == "in_game")
        #expect(a?.lastCaptureAt == ABGTime.parse("2026-10-23T14:05:12.123Z") && a?.lastAppliedAt != nil)
        let bare = LiveControlBody.parse(Data(#"{"teams":[]}"#.utf8))
        #expect(bare?.control == nil && bare?.autoCapture == nil)
        #expect(LiveControlBody.parse(Data("nope".utf8)) == nil)
    }
}

@Suite struct ControlButtonTests {
    @Test func buttonForEveryState() {
        #expect(MatchControlButton.make(MatchControl(state: .locked)) == .start(enabled: false))
        #expect(MatchControlButton.make(MatchControl(state: .ready)) == .start(enabled: true))
        #expect(MatchControlButton.make(MatchControl(state: .live)) == .stop)
        #expect(MatchControlButton.make(MatchControl(state: .ended)) == .none)
        #expect(MatchControlButton.make(MatchControl(state: .published)) == .none)
        // legacy server (no control block): everything allowed as before
        #expect(MatchControlButton.make(nil, legacyStatus: .upcoming) == .start(enabled: true))
        #expect(MatchControlButton.make(nil, legacyStatus: .live) == .stop)
        #expect(MatchControlButton.make(nil) == .start(enabled: true))
        // control wins over the legacy status
        #expect(MatchControlButton.make(MatchControl(state: .locked), legacyStatus: .live) == .start(enabled: false))
    }
}

@Suite struct ControlClientTests {
    @Test func startStopRequestsAndConflicts() async throws {
        let host = "ctl-client.abg.test"
        let s = ABGStub.session(host: host) { r in
            if r.path.hasSuffix("/x/start") { return (409, #"{"error":{"code":"CONFLICT","message":"Match 1 is locked until 10:30 PM."}}"#) }
            if r.path.hasSuffix("/gone/stop") { return (404, #"{"error":{"code":"NOT_FOUND","message":"No such match"}}"#) }
            return (200, #"{"match":{"id":"m 1"},"control":{"state":"live"}}"#)
        }
        let c = StudioLinkClient(host: "https://\(host)", key: goodKey, session: s)
        let body = try await c.startMatch("m 1")
        #expect(LiveControlBody.parse(body)?.control?.state == .live)
        _ = try await c.stopMatch("m 1")
        let reqs = ABGStub.requests(host)
        #expect(reqs[0].method == "POST" && reqs[0].path == "/api/studio-link/matches/m 1/start" && reqs[0].key == goodKey && reqs[0].body == nil)
        #expect(reqs[1].path == "/api/studio-link/matches/m 1/stop")
        await #expect(throws: ABGError.conflict("Match 1 is locked until 10:30 PM.")) { _ = try await c.startMatch("x") }
        await #expect(throws: ABGError.matchNotFound("No such match")) { _ = try await c.stopMatch("gone") }
        #expect(ABGError.conflict("Match 1 is locked until 10:30 PM.").errorDescription == "Match 1 is locked until 10:30 PM.")
    }
    @Test func serviceForwardsStartStop() async throws {
        let host = "ctl-svc.abg.test"
        let s = ABGStub.session(host: host) { _ in (409, #"{"error":{"message":"Match is not live"}}"#) }
        let svc = StudioLinkService(secrets: ABGMemorySecretStore(ABGCredentials(host: "https://\(host)", key: goodKey, account: ABGAccount(name: "A", org: nil))), session: s)
        await #expect(throws: ABGError.conflict("Match is not live")) { _ = try await svc.stopMatch(id: "m1") }
        await #expect(throws: ABGError.notConnected) { _ = try await StudioLinkService(secrets: ABGMemorySecretStore(), session: s).startMatch(id: "m1") }
    }
}

@Suite @MainActor struct ControlControllerTests {
    func make() -> (ABGController, MockBroadcastLinkService) {
        let mock = MockBroadcastLinkService(account: ABGAccount(name: "A", org: nil))
        mock.matchList = MockBroadcastLinkService.controlDemoMatches(now: Date())
        let c = ABGController(service: mock, startPresence: false); c.retryDelay = 0
        return (c, mock)
    }
    @Test func startStopFollowTheServerState() async {
        let (c, mock) = make()
        await c.refreshMatches()
        c.select(c.matches[1])                      // ready
        #expect(c.selectedControl?.state == .ready && c.controlButton == .start(enabled: true) && !c.awaitingResults)
        await c.startMatch()
        #expect(mock.calls.contains("startMatch:c2") && c.selectedControl?.state == .live && c.controlButton == .stop && c.controlMessage == nil)
        await c.stopMatch()
        #expect(c.selectedControl?.state == .ended && c.controlButton == .none && c.awaitingResults && c.stoppedAt != nil)
        // 409: the message is shown, the button keeps following control.state
        await c.stopMatch()
        #expect(c.controlMessage == "Can't stop Match 2: it is ended." && c.selectedControl?.state == .ended && c.controlButton == .none)
    }
    @Test func lockedMatchCannotStartAndConflictMessageIsShown() async {
        let (c, mock) = make()
        await c.refreshMatches()
        c.select(c.matches[0])                      // locked
        #expect(c.controlButton == .start(enabled: false) && c.selectedControl?.reason?.contains("12/16") == true)
        mock.controlConflict = "Registration is open until 10:30 PM."
        await c.startMatch()
        #expect(c.controlMessage == "Registration is open until 10:30 PM." && c.controlButton == .start(enabled: false))
    }
    @Test func legacyMatchAllowsEverything() async {
        let mock = MockBroadcastLinkService(account: ABGAccount(name: "A", org: nil))
        let c = ABGController(service: mock, startPresence: false)
        await c.refreshMatches()
        c.select(c.matches[1])
        #expect(c.selectedControl == nil && c.controlButton == .start(enabled: true))
        await c.startMatch()
        #expect(c.selectedControl?.state == .live && c.controlButton == .stop)
    }
    @Test func liveBodyUpdatesControlAndAutoCapture() async {
        let (c, _) = make()
        await c.refreshMatches()
        c.select(c.matches[1])
        c.ingestLive(Data(#"{"match":{"id":"OTHER"},"control":{"state":"published"}}"#.utf8))
        #expect(c.selectedControl?.state == .ready)                         // another match's answer is ignored
        c.ingestLive(Data(#"{"match":{"id":"c2"},"control":{"state":"live"},"autoCapture":{"paused":true,"lastError":"Too dark"}}"#.utf8))
        #expect(c.selectedControl?.state == .live && c.liveAutoCapture?.paused == true && c.liveAutoCapture?.lastError == "Too dark")
        c.clearSelection()
        #expect(c.selectedControl == nil && c.liveAutoCapture == nil)
    }
    @Test func listPollEvery30sAndWhenTheCountdownEnds() async {
        let (c, mock) = make()
        let now = Date()
        #expect(!c.listRefreshDue(now: now))                                // never loaded, no match picked, picker closed
        c.showMatches = true
        #expect(c.listRefreshDue(now: now))
        await c.refreshMatches(); c.showMatches = false
        let loaded = c.matchesLoadedAt!
        #expect(!c.listRefreshDue(now: loaded.addingTimeInterval(10)))      // nothing picked yet
        c.select(c.matches[1])
        #expect(!c.listRefreshDue(now: loaded.addingTimeInterval(29)) && c.listRefreshDue(now: loaded.addingTimeInterval(30)))
    }
    @Test func countdownReachingZeroRefreshesTheList() async {
        let (c, mock) = make()
        let base = Date()
        mock.matchList[0].control?.unlocksAt = ISO8601DateFormatter().string(from: base.addingTimeInterval(100))
        await c.refreshMatches()                                            // nothing picked, picker closed: only the countdown rule
        let l = c.matchesLoadedAt!
        #expect(!c.listRefreshDue(now: l.addingTimeInterval(50)))
        #expect(c.listRefreshDue(now: base.addingTimeInterval(101)))
    }
}
