import Testing
import Foundation
import CoreGraphics
import ImageIO
import QuartzCore
@testable import Studio

// MARK: helpers

/// URLProtocol stub with response headers (Retry-After) and an optional delay; routes by host.
final class CaptureStub: URLProtocol, @unchecked Sendable {
    struct Seen { var method: String, path: String, key: String?, contentType: String?, body: Data }
    struct Reply { var status: Int; var body: String = "{}"; var headers: [String: String] = [:]; var fail = false }
    typealias Handler = @Sendable (Seen) -> Reply
    nonisolated(unsafe) static var routes: [String: Handler] = [:]
    nonisolated(unsafe) static var seen: [String: [Seen]] = [:]
    static let lock = NSLock()
    static func session(host: String, _ h: @escaping Handler) -> URLSession {
        lock.withLock { routes[host] = h; seen[host] = [] }
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [CaptureStub.self]
        return URLSession(configuration: c)
    }
    static func requests(_ host: String) -> [Seen] { lock.withLock { seen[host] ?? [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        let req = request
        var body = req.httpBody ?? Data()
        if req.httpBody == nil, let st = req.httpBodyStream {
            st.open(); var buf = [UInt8](repeating: 0, count: 65536)
            while st.hasBytesAvailable { let n = st.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            st.close()
        }
        let host = req.url?.host ?? ""
        let s = Seen(method: req.httpMethod ?? "", path: req.url?.path ?? "", key: req.value(forHTTPHeaderField: "X-Studio-Key"),
                     contentType: req.value(forHTTPHeaderField: "Content-Type"), body: body)
        let h = Self.lock.withLock { () -> Handler? in Self.seen[host, default: []].append(s); return Self.routes[host] }
        guard let r = h?(s), !r.fail else { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        var headers = ["Content-Type": "application/json"]; headers.merge(r.headers) { $1 }
        let resp = HTTPURLResponse(url: req.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(r.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Parsed multipart/form-data parts.
struct Part { var name: String; var filename: String?; var contentType: String?; var data: Data; var text: String { String(decoding: data, as: UTF8.self) } }
func parseMultipart(_ body: Data, contentType: String?) -> [Part] {
    guard let ct = contentType, let r = ct.range(of: "boundary=") else { return [] }
    let boundary = Data("--\(ct[r.upperBound...])".utf8)
    var parts: [Part] = []
    var chunks: [Data] = []
    var rest = body[...]
    while let range = rest.range(of: boundary) {
        chunks.append(Data(rest[rest.startIndex..<range.lowerBound])); rest = rest[range.upperBound...]
    }
    for c in chunks.dropFirst() {
        guard let sep = c.range(of: Data("\r\n\r\n".utf8)) else { continue }
        let head = String(decoding: c[c.startIndex..<sep.lowerBound], as: UTF8.self)
        var data = Data(c[sep.upperBound...]); if data.suffix(2) == Data("\r\n".utf8) { data.removeLast(2) }
        func attr(_ k: String) -> String? {
            guard let a = head.range(of: "\(k)=\"") else { return nil }
            let tail = head[a.upperBound...]; return tail.firstIndex(of: "\"").map { String(tail[..<$0]) }
        }
        let ctype = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-type:") }.map { String($0.dropFirst(13)).trimmingCharacters(in: .whitespaces) }
        parts.append(Part(name: attr("name") ?? "", filename: attr("filename"), contentType: ctype, data: data))
    }
    return parts
}

private let key = "sw_capture12345678"

func solidImage(_ w: Int = 1920, _ h: Int = 1080, noise: Bool = false) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    if noise, let p = ctx.data?.assumingMemoryBound(to: UInt32.self) {
        var x: UInt32 = 2463534242
        for i in 0..<(ctx.bytesPerRow / 4 * h) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; p[i] = x | 0xFF000000 }
    } else {
        ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }
    return ctx.makeImage()!
}

func sampleUpload(_ kind: CaptureKind = .liveStatus, jpeg: Data = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0xFF, 0xD9])) -> CaptureUpload {
    CaptureUpload(matchId: "m/1", kind: kind, jpeg: jpeg, captureId: "c-1", capturedAt: Date(timeIntervalSince1970: 1_792_000_000.25), sequence: 7,
                  sessionId: "s-1", sceneId: "scoreboard", sceneName: "Score \"board\" ✓", width: 1920, height: 1080)
}

// MARK: multipart body

@Suite struct CaptureMultipartTests {
    @Test func bodyHasBoundaryFieldsAndFilePart() throws {
        let u = sampleUpload()
        let c = StudioLinkClient(host: "https://abg.test", key: key)
        let r = try c.captureRequest(u, boundary: "XYZ-boundary")
        #expect(r.httpMethod == "POST" && r.url?.absoluteString == "https://abg.test/api/studio-link/matches/m%2F1/screenshots")
        #expect(r.value(forHTTPHeaderField: "X-Studio-Key") == key)
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=XYZ-boundary")
        #expect(r.timeoutInterval == 10)
        let body = try #require(r.httpBody)
        let raw = String(decoding: body, as: UTF8.self)
        #expect(raw.hasPrefix("--XYZ-boundary\r\nContent-Disposition: form-data; name=\"kind\"\r\n\r\nLIVE_STATUS\r\n"))
        #expect(raw.hasSuffix("\r\n--XYZ-boundary--\r\n"))
        #expect(raw.contains("Content-Disposition: form-data; name=\"files\"; filename=\"capture.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"))
        let parts = parseMultipart(body, contentType: r.value(forHTTPHeaderField: "Content-Type"))
        let byName = Dictionary(parts.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(parts.map(\.name) == ["kind", "captureId", "capturedAt", "sequence", "sessionId", "sceneId", "sceneName", "width", "height", "files"])
        #expect(byName["kind"]?.text == "LIVE_STATUS" && byName["captureId"]?.text == "c-1" && byName["sequence"]?.text == "7")
        #expect(byName["capturedAt"]?.text == "2026-10-14T17:46:40.250Z")
        #expect(byName["sessionId"]?.text == "s-1" && byName["sceneId"]?.text == "scoreboard" && byName["sceneName"]?.text == "Score \"board\" ✓")
        #expect(byName["width"]?.text == "1920" && byName["height"]?.text == "1080")
        #expect(byName["files"]?.data == u.jpeg && byName["files"]?.filename == "capture.jpg" && byName["files"]?.contentType == "image/jpeg")
    }
    @Test func kindsMatchTheContract() {
        #expect(CaptureKind.liveStatus.rawValue == "LIVE_STATUS" && CaptureKind.results.rawValue == "RESULTS" && CaptureKind.slotList.rawValue == "SLOT_LIST")
        let b = CaptureMultipart.body(boundary: "b", fields: [("a\"b", "x")], fileField: "files", filename: "c.jpg", fileType: "image/jpeg", file: Data())
        #expect(String(decoding: b, as: UTF8.self).contains("name=\"a%22b\""))
    }
}

// MARK: answers

@Suite struct CaptureReplyTests {
    func reply(_ s: Int, _ body: String = "{}", retry: String? = nil) -> CaptureReply { CaptureReply.from(status: s, body: Data(body.utf8), retryAfter: retry) }
    @Test func classifiesEveryStatus() {
        #expect(reply(202, #"{"captureId":"c","accepted":true,"queuePosition":3,"nextIntervalSeconds":8}"#) == .accepted(captureId: "c", queuePosition: 3, nextIntervalSeconds: 8))
        #expect(reply(200, #"{"captureId":"c","accepted":true}"#) == .duplicate(nextIntervalSeconds: nil))
        #expect(reply(200, #"{"duplicate":true,"nextIntervalSeconds":4}"#) == .duplicate(nextIntervalSeconds: 4))
        #expect(reply(200, #"{"count":1}"#) == .accepted(captureId: nil, queuePosition: nil, nextIntervalSeconds: nil))
        #expect(reply(400, #"{"error":{"message":"Bad kind"}}"#) == .badRequest("Bad kind"))
        #expect(reply(400, "oops") == .badRequest("AirBattleground rejected the capture."))
        #expect(reply(401) == .keyRejected && reply(403) == .keyRejected)
        #expect(reply(404, #"{"error":{"message":"Match not found"}}"#) == .matchNotFound("Match not found"))
        #expect(reply(409) == .conflict(nil))
        #expect(reply(409, #"{"error":{"code":"CONFLICT","message":"Match is published"}}"#) == .conflict("Match is published"))
        #expect(reply(413) == .tooLarge)
        #expect(reply(429, retry: "12") == .rateLimited(retryAfter: 12))
        #expect(reply(429) == .rateLimited(retryAfter: nil))
        #expect(reply(503) == .serverError(503, nil) && reply(500, #"{"error":{"message":"db down"}}"#) == .serverError(500, "db down"))
    }
    @Test func retryAfterAsHttpDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        #expect(CaptureReply.parseRetryAfter(f.string(from: now.addingTimeInterval(20)), now: now) == 20)
        #expect(CaptureReply.parseRetryAfter("soon", now: now) == nil)
    }
    @Test func clientMapsHeadersAndTransportFailures() async {
        let host = "reply.capture.test"
        let s = CaptureStub.session(host: host) { seen in
            seen.body.count > 0 ? CaptureStub.Reply(status: 429, headers: ["Retry-After": "7"]) : CaptureStub.Reply(status: 500)
        }
        let c = StudioLinkClient(host: "https://\(host)", key: key, session: s)
        #expect(await c.uploadCapture(sampleUpload()) == .rateLimited(retryAfter: 7))
        let down = StudioLinkClient(host: "https://down.capture.test", key: key,
                                    session: CaptureStub.session(host: "down.capture.test") { _ in CaptureStub.Reply(status: 0, fail: true) })
        #expect(await down.uploadCapture(sampleUpload()) == .unreachable)
    }
    @Test func serviceUploadWithoutCredentialsIsRejected() async {
        let svc = StudioLinkService(secrets: ABGMemorySecretStore(), session: .shared)
        #expect(await svc.uploadCapture(sampleUpload()) == .keyRejected)
    }
}

// MARK: state machine (pure)

@Suite struct CapturePolicyTests {
    @Test func acceptedUsesServerIntervalClamped() {
        #expect(CapturePolicy.decide(.accepted(captureId: nil, queuePosition: nil, nextIntervalSeconds: nil), interval: 5, failures: 2)
                == CaptureDecision(delay: 5, sent: true))
        #expect(CapturePolicy.decide(.accepted(captureId: "c", queuePosition: 1, nextIntervalSeconds: 8), interval: 5, failures: 0).delay == 8)
        #expect(CapturePolicy.decide(.accepted(captureId: "c", queuePosition: 1, nextIntervalSeconds: 0.5), interval: 5, failures: 0).delay == 2)
        #expect(CapturePolicy.decide(.accepted(captureId: "c", queuePosition: 1, nextIntervalSeconds: 600), interval: 5, failures: 0).delay == 60)
        let dup = CapturePolicy.decide(.duplicate(nextIntervalSeconds: nil), interval: 3, failures: 0)
        #expect(dup.delay == 3 && !dup.sent && dup.message == nil)
    }
    @Test func stopsOnOperatorProblems() {
        let bad = CapturePolicy.decide(.badRequest("Bad kind"), interval: 5, failures: 0)
        #expect(bad.stops && bad.message == "AirBattleground: Bad kind" && bad.fix == nil)
        let key = CapturePolicy.decide(.keyRejected, interval: 5, failures: 0)
        #expect(key.stops && key.fix == .connect && key.message == "AirBattleground didn't accept the studio key.")
        let nf = CapturePolicy.decide(.matchNotFound(nil), interval: 5, failures: 0)
        #expect(nf.stops && nf.fix == .selectMatch && nf.message?.contains("Match not found") == true)
    }
    @Test func captureDoneStopsWithoutAnError() {
        let body = Data(#"{"error":{"code":"CAPTURE_DONE","message":"All results are in"}}"#.utf8)
        #expect(CaptureReply.from(status: 409, body: body) == .finished("All results are in"))
        #expect(CaptureReply.from(status: 409, body: Data(#"{"error":{"code":"CONFLICT","message":"Match is published"}}"#.utf8)) == .conflict("Match is published"))
        let d = CapturePolicy.decide(.finished("All results are in"), interval: 5, failures: 0)
        #expect(d.stops && d.finished && d.message == nil && !d.paused)
    }
    @Test func pausesRateLimitsAndBacksOff() {
        let nl = CapturePolicy.decide(.conflict("Match is published"), interval: 5, failures: 0)
        #expect(nl.delay == 30 && nl.paused && nl.message == "Match is published")
        #expect(CapturePolicy.decide(.rateLimited(retryAfter: 12), interval: 5, failures: 0).delay == 12)
        #expect(CapturePolicy.decide(.rateLimited(retryAfter: nil), interval: 5, failures: 0).delay == 30)
        let a = CapturePolicy.decide(.serverError(503, nil), interval: 5, failures: 0)
        let b = CapturePolicy.decide(.unreachable, interval: 5, failures: a.failures)
        let c = CapturePolicy.decide(.serverError(500, nil), interval: 5, failures: b.failures)
        let d = CapturePolicy.decide(.serverError(500, nil), interval: 5, failures: c.failures)
        #expect([a, b, c, d].map(\.delay) == [5, 10, 30, 30] && d.failures == 4 && !a.sent)
        // a success resets the backoff
        #expect(CapturePolicy.decide(.accepted(captureId: nil, queuePosition: nil, nextIntervalSeconds: nil), interval: 5, failures: 4).failures == 0)
        #expect(CapturePolicy.decide(.tooLarge, interval: 5, failures: 0).delay == 5)
    }
}

// MARK: scheduler (session)

@MainActor final class FakeStudio {
    var connected = true
    var matchId: String? = "m1"
    var program: String? = "s1"
    var scenes: [LayerScene] = [LayerScene(id: "s1", name: "Scoreboard"), LayerScene(id: "s2", name: "Results")]
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let mock = MockBroadcastLinkService(account: ABGAccount(name: "A", org: nil))
    var renders = 0
    var feeds: [CaptureFeed] = []
    var control: MatchControl.State?
    func env(render: CaptureRenderer? = nil) -> CaptureEnvironment {
        let m = mock
        return CaptureEnvironment(isConnected: { [unowned self] in connected }, matchId: { [unowned self] in matchId },
                                  programSceneId: { [unowned self] in program }, scene: { [unowned self] id in scenes.first { $0.id == id } },
                                  render: render ?? { _, size in solidImage(Int(size.width), Int(size.height)) },
                                  upload: { u in await m.uploadCapture(u) }, now: { [unowned self] in now },
                                  feeds: { [unowned self] in feeds },
                                  captureResult: { mid, cid in await m.captureResult(matchId: mid, captureId: cid) },
                                  controlState: { [unowned self] in control },
                                  sleep: { _ in await Task.yield() })
    }
}

@Suite(.serialized) @MainActor struct CaptureSchedulerTests {
    func make(_ kind: CaptureKind? = nil, interval: Double = 5) -> (AutoCaptureSession, FakeStudio) {
        let f = FakeStudio()
        return (AutoCaptureSession(kind: kind, interval: interval, env: f.env()), f)
    }
    func tick(_ s: AutoCaptureSession, _ f: FakeStudio, advance: Double) async {
        f.now = f.now.addingTimeInterval(advance)
        s.pump(now: f.now)
        await s.currentTask?.value
    }

    @Test func startFiresAtOnceThenEveryInterval() async {
        let (s, f) = make()
        #expect(s.start(now: f.now.addingTimeInterval(-s.interval)))
        #expect(s.sceneId == "s1")                       // defaults to the scene on Program, pinned
        await tick(s, f, advance: 0)
        #expect(f.mock.uploads.count == 1 && s.sentCount == 1 && s.lastSentAt == f.now)
        let u = f.mock.uploads[0]
        #expect(u.kind == nil && u.trigger == .auto && u.hint == nil && u.matchId == "m1" && u.sceneId == "s1" && u.sceneName == "Scoreboard" && u.sequence == 1 && u.width == 1920 && u.height == 1080)
        #expect(u.jpeg.prefix(2) == Data([0xFF, 0xD8]) && u.jpeg.count <= CaptureEncoder.maxBytes)
        #expect(s.nextDueAt == f.now.addingTimeInterval(5))
        await tick(s, f, advance: 4.9)
        #expect(f.mock.uploads.count == 1)               // not due yet
        await tick(s, f, advance: 0.1)
        #expect(f.mock.uploads.count == 2 && f.mock.uploads[1].sequence == 2 && f.mock.uploads[1].sessionId == u.sessionId)
        #expect(f.mock.uploads[1].captureId != u.captureId)
        #expect(s.statusLine.hasPrefix("Capturing every 5 s · last sent ") && s.statusLine.hasSuffix("· 2 sent"))
    }
    @Test func serverIntervalOverridesTheNextTick() async {
        let (s, f) = make()
        f.mock.captureReply = .accepted(captureId: "c", queuePosition: 2, nextIntervalSeconds: 12)
        s.start(now: f.now.addingTimeInterval(-s.interval)); await tick(s, f, advance: 0)
        #expect(s.nextDueAt == f.now.addingTimeInterval(12) && s.effectiveInterval == 12)
        await tick(s, f, advance: 6)
        #expect(f.mock.uploads.count == 1)
        f.mock.captureReply = .accepted(captureId: "c", queuePosition: 2, nextIntervalSeconds: 1)
        await tick(s, f, advance: 6)
        #expect(f.mock.uploads.count == 2 && s.nextDueAt == f.now.addingTimeInterval(5) && s.effectiveInterval == 5)   // never faster than the operator's 5 s
    }
    @Test func skipsWhileThePreviousUploadIsInFlight() async {
        let (s, f) = make(interval: 2)
        f.mock.captureDelay = 0.3
        s.start(now: f.now.addingTimeInterval(-s.interval))
        f.now = f.now.addingTimeInterval(0); s.pump(now: f.now)
        let first = s.currentTask
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(s.inFlight)
        f.now = f.now.addingTimeInterval(2.5); s.pump(now: f.now)      // due again while uploading
        #expect(s.skipped == 1)
        await first?.value
        #expect(f.mock.uploads.count == 1 && !s.inFlight)
        s.captureOnce(); await s.currentTask?.value                   // manual capture still works afterwards
        #expect(f.mock.uploads.count == 2)
    }
    @Test func stopStopsTicking() async {
        let (s, f) = make()
        s.start(now: f.now.addingTimeInterval(-s.interval)); await tick(s, f, advance: 0)
        s.stop()
        #expect(!s.running && s.nextDueAt == nil)
        await tick(s, f, advance: 60)
        #expect(f.mock.uploads.count == 1 && s.statusLine.hasPrefix("Stopped · last sent"))
    }
    @Test func refusesToStartWithoutConnectionOrMatch() {
        let (s, f) = make()
        f.connected = false
        #expect(!s.start() && s.fix == .connect && !s.running)
        f.connected = true; f.matchId = nil
        #expect(!s.start() && s.fix == .selectMatch)
        f.matchId = "m1"; f.program = nil
        #expect(!s.start() && s.message == "Pick a clean feed or a scene to capture.")
        f.control = .published
        s.sceneId = "s2"
        #expect(!s.start() && s.message == "This match is published. Screenshots are closed.")
        f.control = .locked
        s.sceneId = "s2"
        #expect(s.start() && s.message == nil)
    }
    @Test func keyRejectedStopsAndAsksToConnect() async {
        let (s, f) = make()
        f.mock.captureReply = .keyRejected
        s.start(now: f.now.addingTimeInterval(-s.interval)); await tick(s, f, advance: 0)
        #expect(!s.running && s.fix == .connect && s.statusLine == "AirBattleground didn't accept the studio key.")
    }
    @Test func notFoundAndBadRequestStop() async {
        let (s, f) = make()
        f.mock.captureReply = .matchNotFound(nil)
        s.start(now: f.now.addingTimeInterval(-s.interval)); await tick(s, f, advance: 0)
        #expect(!s.running && s.fix == .selectMatch)
        f.mock.captureReply = .badRequest("Unsupported kind")
        s.start(now: f.now.addingTimeInterval(-s.interval)); await tick(s, f, advance: 0)
        #expect(!s.running && s.message == "AirBattleground: Unsupported kind" && s.fix == nil)
    }
    @Test func conflictPausesShowsTheMessageAndRetriesEvery30s() async {
        let (s, f) = make()
        f.mock.captureReplies = [.conflict("Match 1 is published."), .conflict(nil)]
        s.start(now: f.now.addingTimeInterval(-s.interval)); await tick(s, f, advance: 0)
        #expect(s.running && s.paused && s.nextDueAt == f.now.addingTimeInterval(30) && s.statusLine == "Match 1 is published.")
        await tick(s, f, advance: 10); #expect(f.mock.uploads.count == 1)
        await tick(s, f, advance: 20); #expect(f.mock.uploads.count == 2 && s.paused)
        await tick(s, f, advance: 30)                                    // now accepted
        #expect(f.mock.uploads.count == 3 && !s.paused && s.message == nil && s.nextDueAt == f.now.addingTimeInterval(5))
    }
    @Test func tooLargeRetriesOnceSmaller() async {
        let f = FakeStudio()
        let s = AutoCaptureSession(kind: .liveStatus, interval: 5, env: f.env(render: { _, size in solidImage(Int(size.width), Int(size.height), noise: true) }))
        f.mock.captureReplies = [.tooLarge]
        s.start(now: f.now.addingTimeInterval(-s.interval)); await tick(s, f, advance: 0)
        let ups = f.mock.uploads
        #expect(ups.count == 2 && ups[1].jpeg.count < ups[0].jpeg.count && ups[1].jpeg.count <= CaptureEncoder.maxBytes / 2)
        #expect(ups[0].captureId == ups[1].captureId && s.sentCount == 1)
        f.mock.captureReplies = [.tooLarge, .tooLarge]
        await tick(s, f, advance: 5)
        #expect(f.mock.uploads.count == 4 && s.running && s.message?.contains("too large") == true)
    }
    @Test func rateLimitWaitsRetryAfter() async {
        let (s, f) = make()
        f.mock.captureReply = .rateLimited(retryAfter: 17)
        s.start(now: f.now.addingTimeInterval(-s.interval)); await tick(s, f, advance: 0)
        #expect(s.running && s.nextDueAt == f.now.addingTimeInterval(17) && s.sentCount == 0)
    }
    @Test func serverErrorsBackOff5_10_30() async {
        let (s, f) = make(interval: 2)
        f.mock.captureReplies = [.serverError(502, nil), .unreachable, .serverError(500, nil)]
        s.start(now: f.now.addingTimeInterval(-s.interval))
        await tick(s, f, advance: 0); #expect(s.nextDueAt == f.now.addingTimeInterval(5))
        await tick(s, f, advance: 5); #expect(s.nextDueAt == f.now.addingTimeInterval(10))
        await tick(s, f, advance: 10); #expect(s.nextDueAt == f.now.addingTimeInterval(30) && s.running)
        await tick(s, f, advance: 30)
        #expect(s.nextDueAt == f.now.addingTimeInterval(2) && s.message == nil && s.sentCount == 1)
    }
    @Test func losingTheMatchStopsAtTheNextTick() async {
        let (s, f) = make()
        s.start(now: f.now.addingTimeInterval(-s.interval)); await tick(s, f, advance: 0)
        f.matchId = nil
        await tick(s, f, advance: 5)
        #expect(!s.running && s.fix == .selectMatch && f.mock.uploads.count == 1)
    }
    @Test func legacyKindIsStillSentWhenSet() async {
        let (s, f) = make(.results, interval: 10)
        s.sceneId = "s2"
        s.captureOnce(); await s.currentTask?.value
        #expect(f.mock.uploads.map(\.kind) == [.results] && f.mock.uploads[0].sceneName == "Results" && f.mock.uploads[0].sequence == 1)
        #expect(!s.running && s.statusLine.hasPrefix("Sent at") && s.thumbnail?.width == 320)
    }
    @Test func controllerAutoCaptureFromSceneCard() async {
        let f = FakeStudio()
        let c = AutoCaptureController(env: f.env(), startLoop: false)
        c.autoCapture(sceneId: "s2")
        #expect(c.live.running && c.live.sceneId == "s2" && c.anyRunning && c.focusRequest == 1 && c.session === c.live)
        c.stopAll(); #expect(!c.anyRunning)
        c.setAuto(true); #expect(c.live.running)
        c.setAuto(false); #expect(!c.live.running)
    }
}

// MARK: JPEG

@Suite struct CaptureJPEGTests {
    @Test func normalFrameIsQuality085AndSmall() throws {
        let r = try #require(CaptureEncoder.capped(solidImage()))
        #expect(r.quality == 0.85 && r.data.count < 200_000 && r.data.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
        let src = try #require(CGImageSourceCreateWithData(r.data as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        #expect(props?[kCGImagePropertyPixelWidth] as? Int == 1920 && props?[kCGImagePropertyPixelHeight] as? Int == 1080)
    }
    @Test func noisyFrameStaysUnderTheCap() throws {
        let img = solidImage(noise: true)
        let full = try #require(CaptureEncoder.jpeg(img, quality: 0.85))
        #expect(full.count > 2_000_000)                       // white noise is worst case: above 2 MB at 0.85
        let r = try #require(CaptureEncoder.capped(img))
        #expect(r.data.count <= CaptureEncoder.maxBytes && r.quality < 0.85)
        let tight = try #require(CaptureEncoder.capped(img, maxBytes: 300_000))
        #expect(tight.data.count <= 300_000)
    }
}

// MARK: persistence

@Suite @MainActor struct CapturePersistenceTests {
    @Test func choicesSurviveRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("capture-store-\(UUID().uuidString)")
        let f = FakeStudio()
        let c = AutoCaptureController(env: f.env(), persistence: AutoCaptureStorePersistence(store: try StudioStore(dir: dir)), startLoop: false)
        #expect(c.live.interval == 5 && c.live.source == nil)
        c.live.source = .feed(.device(id: "ph1")); c.live.interval = 3
        let json = try String(contentsOf: dir.appendingPathComponent("store.json"), encoding: .utf8)
        #expect(json.contains("autoCapture") && json.contains("feed:device:ph1"))
        let c2 = AutoCaptureController(env: f.env(), persistence: AutoCaptureStorePersistence(store: try StudioStore(dir: dir)), startLoop: false)
        #expect(c2.live.source == .feed(.device(id: "ph1")) && c2.live.interval == 3)
        c2.live.sceneId = "s2"
        let c3 = AutoCaptureController(env: f.env(), persistence: AutoCaptureStorePersistence(store: try StudioStore(dir: dir)), startLoop: false)
        #expect(c3.live.sceneId == "s2" && c3.live.source == .scene("s2"))
    }
    @Test func legacyTwoCardSettingsMigrate() {
        let p = AutoCaptureMemoryPersistence()
        p.settings = AutoCaptureSettings(liveSceneId: "s1", liveInterval: 10, resultsSceneId: "s2", resultsInterval: 15)
        let c = AutoCaptureController(env: FakeStudio().env(), persistence: p, startLoop: false)
        #expect(c.live.source == .scene("s1") && c.live.interval == 10)
    }
    @Test func oldStoreWithoutCaptureStillLoads() throws {
        let s = AutoCaptureSettings(liveSceneId: "a", liveInterval: 2, resultsSceneId: nil, resultsInterval: 10)
        let back = try JSONDecoder().decode(AutoCaptureSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        let doc = try JSONDecoder().decode(StoreDoc.self, from: Data(#"{"settings":{"name":"X"}}"#.utf8))
        #expect(doc.settings.name == "X" && doc.settings.autoCapture == nil)
    }
}

// MARK: integration: a real engine frame goes over HTTP

@Suite(.serialized) @MainActor struct CaptureIntegrationTests {
    @Test func realRenderStillIsUploadedWithoutKind() async throws {
        let host = "int.capture.test"
        let session = CaptureStub.session(host: host) { _ in
            CaptureStub.Reply(status: 202, body: #"{"captureId":"x","accepted":true,"queuePosition":1,"nextIntervalSeconds":7}"#)
        }
        let secrets = ABGMemorySecretStore(ABGCredentials(host: "https://\(host)", key: key, account: ABGAccount(name: "A", org: nil)))
        let svc = StudioLinkService(secrets: secrets, session: session)
        let abg = ABGController(service: svc, startPresence: false)
        abg.select(ABGMatch(id: "match-42", title: "Dragons vs Wolves", subtitle: "Final", startsAt: nil, status: .live))
        nonisolated(unsafe) let engine = StudioEngine()
        let scene = LayerScene(id: "board", name: "Scoreboard", layers: [
            .rect(x: 0, y: 0, w: 960, h: 1080),
            .text("Title", "DRAGONS 3 - 1 WOLVES", x: 200, y: 400, w: 1500, h: 200)])
        let env = CaptureEnvironment(
            isConnected: { abg.isConnected }, matchId: { abg.link?.eventId }, programSceneId: { "board" },
            scene: { $0 == "board" ? scene : nil },
            render: { s, size in engine.renderStill(s, size: size, variables: engine.sceneVariables, time: CACurrentMediaTime(), clock: nil) },
            upload: { u in await svc.uploadCapture(u) })
        let c = AutoCaptureController(env: env, startLoop: false)
        #expect(c.live.start(now: Date().addingTimeInterval(-c.live.interval)))
        c.live.pump(now: Date()); await c.live.currentTask?.value
        #expect(c.live.sentCount == 1 && c.live.effectiveInterval == 7 && c.live.message == nil)

        let req = try #require(CaptureStub.requests(host).first)
        #expect(req.method == "POST" && req.path == "/api/studio-link/matches/match-42/screenshots" && req.key == key)
        let parts = parseMultipart(req.body, contentType: req.contentType)
        let file = try #require(parts.first { $0.name == "files" })
        #expect(parts.first { $0.name == "kind" } == nil && parts.first { $0.name == "trigger" }?.text == "auto" && parts.first { $0.name == "hint" } == nil)
        #expect(parts.first { $0.name == "sceneName" }?.text == "Scoreboard" && parts.first { $0.name == "sequence" }?.text == "1")
        #expect(file.contentType == "image/jpeg" && file.filename == "capture.jpg" && file.data.count <= CaptureEncoder.maxBytes)
        // the JPEG is a real 1080p frame of the scene: white rect on the left, dark background on the right
        let src = try #require(CGImageSourceCreateWithData(file.data as CFData, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(img.width == 1920 && img.height == 1080)
        let ctx = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 1920 * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        func lum(_ x: Int, _ y: Int) -> Int { let o = (y * 1920 + x) * 4; return (Int(p[o]) + Int(p[o + 1]) + Int(p[o + 2])) / 3 }
        #expect(lum(100, 100) > 200 && lum(1800, 100) < 80)
        try? file.data.write(to: URL(fileURLWithPath: "/tmp/capture-integration.jpg"))
    }
}

// MARK: - new contract: no kind, trigger / hint, busy / duplicate

@Suite struct CaptureContractTests {
    @Test func uploadWithoutKindCarriesTriggerAndHint() throws {
        var u = sampleUpload()
        u.kind = nil; u.trigger = .manual; u.hint = .inGame
        let r = try StudioLinkClient(host: "https://abg.test", key: key).captureRequest(u, boundary: "B")
        let parts = parseMultipart(try #require(r.httpBody), contentType: r.value(forHTTPHeaderField: "Content-Type"))
        #expect(parts.map(\.name) == ["captureId", "capturedAt", "sequence", "sessionId", "sceneId", "sceneName", "width", "height", "trigger", "hint", "files"])
        let by = Dictionary(parts.map { ($0.name, $0.text) }, uniquingKeysWith: { a, _ in a })
        #expect(by["trigger"] == "manual" && by["hint"] == "in_game" && by["captureId"] == "c-1")
        u.trigger = .auto; u.hint = nil; u.kind = .auto
        #expect(u.fields.map(\.0) == ["kind", "captureId", "capturedAt", "sequence", "sessionId", "sceneId", "sceneName", "width", "height", "trigger"])
        #expect(u.fields.first?.1 == "AUTO" && CaptureHint.allCases.map(\.rawValue) == ["lobby", "results", "in_game"])
    }
    @Test func busyAndDuplicateAnswers() {
        func reply(_ s: Int, _ b: String) -> CaptureReply { CaptureReply.from(status: s, body: Data(b.utf8)) }
        #expect(reply(202, #"{"accepted":false,"reason":"busy","nextIntervalSeconds":6}"#) == .busy(nextIntervalSeconds: 6))
        #expect(reply(200, #"{"accepted":false,"reason":"busy"}"#) == .busy(nextIntervalSeconds: nil))
        #expect(reply(200, #"{"captureId":"c","accepted":false,"duplicate":true}"#) == .duplicate(nextIntervalSeconds: nil))
        #expect(reply(202, #"{"captureId":"c","accepted":false,"duplicate":true}"#) == .duplicate(nextIntervalSeconds: nil))
        #expect(reply(202, #"{"captureId":"c","accepted":true,"queuePosition":2,"nextIntervalSeconds":5}"#) == .accepted(captureId: "c", queuePosition: 2, nextIntervalSeconds: 5))
        let busy = CapturePolicy.decide(.busy(nextIntervalSeconds: nil), interval: 5, failures: 3)
        #expect(busy.delay == 5 && busy.busy && !busy.sent && busy.message == nil && busy.failures == 0 && !busy.stops)
        #expect(CapturePolicy.manualOutcome(.busy(nextIntervalSeconds: nil))?.tone == .warn)
        #expect(CapturePolicy.manualOutcome(.duplicate(nextIntervalSeconds: nil))?.text.contains("Already sent") == true)
        #expect(CapturePolicy.manualOutcome(.conflict("Match is published")) == CaptureOutcome(text: "Match is published", tone: .error))
        #expect(CapturePolicy.manualOutcome(.accepted(captureId: "c", queuePosition: 1, nextIntervalSeconds: nil)) == nil)
    }
}

@Suite(.serialized) @MainActor struct CaptureBusyTests {
    @Test func busyCarriesOnWithoutError() async {
        let f = FakeStudio()
        let s = AutoCaptureSession(interval: 5, env: f.env())
        f.mock.captureReplies = [.busy(nextIntervalSeconds: nil)]
        s.start(now: f.now.addingTimeInterval(-s.interval)); s.pump(now: f.now); await s.currentTask?.value
        #expect(s.running && !s.paused && s.message == nil && s.busyCount == 1 && s.sentCount == 0 && s.nextDueAt == f.now.addingTimeInterval(5))
        f.mock.captureReplies = [.duplicate(nextIntervalSeconds: nil)]
        f.now = f.now.addingTimeInterval(5); s.pump(now: f.now); await s.currentTask?.value
        #expect(s.running && s.message == nil && s.sentCount == 0)
    }
}

// MARK: - capture result polling (GET …/captures/{captureId})

@Suite struct CaptureResultTests {
    @Test func stepStateMachine() {
        let applied = CaptureResult(status: .applied, detected: "lobby", message: "Read 14 teams from the lobby")
        #expect(CaptureResultPolling.step(.result(CaptureResult(status: .queued)), elapsed: 0) == .wait)
        #expect(CaptureResultPolling.step(.result(CaptureResult(status: .reading)), elapsed: 30) == .wait)
        #expect(CaptureResultPolling.step(.result(applied), elapsed: 3) == .done(applied))
        #expect(CaptureResultPolling.step(.failed("x"), elapsed: 10) == .wait)       // transient: keep polling
        #expect(CaptureResultPolling.step(.notFound, elapsed: 1.5) == .wait)
        #expect(CaptureResultPolling.step(.notFound, elapsed: 10.5) == .gone)
        #expect(CaptureResultPolling.step(.result(CaptureResult(status: .queued)), elapsed: 60) == .timedOut)
        #expect(CaptureResultPolling.interval == 1.5 && CaptureResultPolling.timeout == 60)
    }
    @Test func outcomesShownToTheOperator() throws {
        #expect(CaptureOutcome.from(CaptureResult(status: .applied, detected: "lobby", message: "Read 14 teams from the lobby")).text == "Lobby ✓ 14 teams")
        #expect(CaptureOutcome.from(CaptureResult(status: .applied, detected: "results", message: "Results page 1 read")).text == "Results ✓ page 1")
        let ig = CaptureOutcome.from(CaptureResult(status: .applied, detected: "in_game", message: "Updated 3 teams"))
        #expect(ig.text == "In-game ✓ 3 teams" && ig.tone == .ok)
        #expect(CaptureOutcome.from(CaptureResult(status: .ignored, detected: "other")) == CaptureOutcome(text: "Not a game screen. Check the scene", tone: .warn))
        #expect(CaptureOutcome.from(CaptureResult(status: .ignored, detected: nil)).text == "Not a game screen. Check the scene")
        let failed = CaptureOutcome.from(CaptureResult(status: .failed, message: "Image unreadable"))
        #expect(failed.text == "Image unreadable" && failed.tone == .error)
        #expect(CaptureOutcome.from(CaptureResult(status: .reading)).tone == .progress)
        let json = #"{"captureId":"c9","status":"applied","detected":"lobby","confidence":0.93,"message":"Read 14 teams from the lobby"}"#
        let r = try JSONDecoder().decode(CaptureResult.self, from: Data(json.utf8))
        #expect(r.captureId == "c9" && r.status == .applied && r.detected == "lobby" && r.confidence == 0.93 && r.isFinal)
        let odd = try JSONDecoder().decode(CaptureResult.self, from: Data(#"{"status":"weird","detected":null}"#.utf8))
        #expect(odd.status == .queued && odd.detected == nil && !odd.isFinal)
    }
    @Test func clientPollsTheCapturePath() async {
        let host = "result.capture.test"
        let s = CaptureStub.session(host: host) { seen in
            seen.path.hasSuffix("/captures/gone") ? CaptureStub.Reply(status: 404)
                : CaptureStub.Reply(status: 200, body: #"{"captureId":"c1","status":"reading","detected":null}"#)
        }
        let c = StudioLinkClient(host: "https://\(host)", key: key, session: s)
        #expect(await c.captureResult(matchId: "m 1", captureId: "c1") == .result(CaptureResult(captureId: "c1", status: .reading)))
        #expect(await c.captureResult(matchId: "m 1", captureId: "gone") == .notFound)
        let req = CaptureStub.requests(host)[0]
        #expect(req.method == "GET" && req.path == "/api/studio-link/matches/m 1/captures/c1" && req.key == key)
    }
}

@Suite(.serialized) @MainActor struct CaptureManualTests {
    @Test func manualScreenshotPollsUntilApplied() async {
        let f = FakeStudio()
        let c = AutoCaptureController(env: f.env(), startLoop: false)
        let s = c.live
        f.mock.captureReply = .accepted(captureId: "srv-1", queuePosition: 1, nextIntervalSeconds: nil)
        f.mock.captureResults = [.notFound, .result(CaptureResult(status: .queued)), .result(CaptureResult(status: .reading))]
        f.mock.captureResultReply = .result(CaptureResult(captureId: "srv-1", status: .applied, detected: "lobby", message: "Read 14 teams from the lobby"))
        s.hint = .lobby
        c.sendScreenshot(); await s.currentTask?.value; await s.pollTask?.value
        let u = f.mock.uploads[0]
        #expect(u.trigger == .manual && u.hint == .lobby && u.kind == nil)
        #expect(f.mock.calls.filter { $0.hasPrefix("captureResult:srv-1") }.count == 4)
        #expect(s.manualOutcome?.text == "Lobby ✓ 14 teams" && s.lastDetected == "lobby" && !s.manualPolling)
        #expect(c.toast?.text == "Lobby ✓ 14 teams")
    }
    @Test func manualScreenshotTimesOutAfter60s() async {
        let f = FakeStudio()
        let s = AutoCaptureSession(interval: 5, env: f.env())
        f.mock.captureResultReply = .result(CaptureResult(status: .queued))
        s.captureOnce(); await s.currentTask?.value; await s.pollTask?.value
        #expect(s.manualOutcome == .timedOut)
        #expect(f.mock.calls.filter { $0.hasPrefix("captureResult:") }.count == 41)   // 0, 1.5, … 60 s
    }
    @Test func manualFailuresAndConflict() async {
        let f = FakeStudio()
        let s = AutoCaptureSession(interval: 5, env: f.env())
        f.mock.captureResultReply = .result(CaptureResult(status: .failed, message: "Could not read the image"))
        s.captureOnce(); await s.currentTask?.value; await s.pollTask?.value
        #expect(s.manualOutcome?.tone == .error && s.manualOutcome?.text == "Could not read the image")
        f.mock.captureResultReply = .result(CaptureResult(status: .ignored, detected: "other"))
        s.captureOnce(); await s.currentTask?.value; await s.pollTask?.value
        #expect(s.manualOutcome?.text == "Not a game screen. Check the scene")
        f.mock.captureReply = .conflict("Match 1 is published.")
        let before = f.mock.calls.count
        s.captureOnce(); await s.currentTask?.value
        #expect(s.manualOutcome == CaptureOutcome(text: "Match 1 is published.", tone: .error) && s.paused == false)
        #expect(!f.mock.calls.suffix(from: before).contains { $0.hasPrefix("captureResult:") })
    }
    @Test func manualDuringAnAutoUploadRunsRightAfter() async {
        let f = FakeStudio()
        let s = AutoCaptureSession(interval: 5, env: f.env())
        f.mock.captureDelay = 0.2
        s.start(now: f.now.addingTimeInterval(-s.interval)); s.pump(now: f.now)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(s.inFlight)
        s.captureOnce()
        #expect(s.manualPending)
        for _ in 0..<40 where f.mock.uploads.count < 2 { try? await Task.sleep(nanoseconds: 50_000_000) }
        await s.currentTask?.value
        #expect(f.mock.uploads.map(\.trigger) == [.auto, .manual] && s.running && !s.manualPending)
        #expect(f.mock.uploads[1].sessionId == f.mock.uploads[0].sessionId && f.mock.uploads[1].sequence == 2)
    }
}

// MARK: - clean feed

@Suite(.serialized) @MainActor struct CaptureCleanFeedTests {
    @Test func cleanFeedSceneIsTheRawSourceFullFrame() {
        let f = CaptureFeed(ref: .device(id: "ph1"), name: "Phone A")
        let sc = CleanFeed.scene(f)
        #expect(sc.name == "Clean feed: Phone A" && sc.id == "clean-feed:device:ph1" && sc.layers.count == 1 && sc.sourceRefs == [.device(id: "ph1")])
        let l = sc.layers[0]
        #expect(l.transform.x == 0 && l.transform.y == 0 && l.transform.w == 1920 && l.transform.h == 1080)
        if case .source(let r, let fit) = l.kind { #expect(r == .device(id: "ph1") && fit == .fill) } else { Issue.record("not a source layer") }
        #expect(!CleanFeed.hasOverlays(sc) && f.label == "Clean feed: Phone A (recommended)")
    }
    @Test func overlayDetection() {
        let board = LayerScene(name: "Game + board", layers: [.source("P", .device(id: "x"), x: 0, y: 0, w: 1920, h: 1080),
                                                             Layer(name: "Board", kind: .teamBoard(TeamBoardSpec()))])
        let nested = LayerScene(name: "Lower third", layers: [.group("G", [.text("T", "{{matchTitle}}", x: 0, y: 0, w: 100, h: 50)])])
        var hidden = LayerScene(name: "Hidden", layers: [.text("T", "x", x: 0, y: 0, w: 10, h: 10)]); hidden.layers[0].visible = false
        #expect(CleanFeed.hasOverlays(board) && CleanFeed.hasOverlays(nested) && !CleanFeed.hasOverlays(hidden))
        #expect(CleanFeed.overlayWarning == "This scene has overlays the reader may misread — pick a clean feed")
    }
    @Test func defaultSourceIsTheFirstLiveCleanFeed() async {
        let f = FakeStudio()
        f.feeds = [CaptureFeed(ref: .device(id: "off"), name: "Phone Off", online: false), CaptureFeed(ref: .device(id: "ph1"), name: "Phone A")]
        f.scenes.append(LayerScene(id: "s3", name: "Board", layers: [Layer(name: "Board", kind: .teamBoard(TeamBoardSpec()))]))
        let s = AutoCaptureSession(interval: 5, env: f.env())
        #expect(s.resolvedSource == .feed(.device(id: "ph1")) && s.overlayWarning == nil && s.sceneName == "Clean feed: Phone A")
        s.captureOnce(); await s.currentTask?.value; await s.pollTask?.value
        let u = f.mock.uploads[0]
        #expect(u.sceneName == "Clean feed: Phone A" && u.sceneId == "clean-feed:device:ph1")
        s.sceneId = "s3"
        #expect(s.overlayWarning == CleanFeed.overlayWarning)
        s.sceneId = "s1"
        #expect(s.overlayWarning == nil)
        s.source = .feed(.device(id: "gone"))        // unplugged phone -> back to the default
        #expect(s.resolvedSource == .feed(.device(id: "ph1")))
        #expect(CaptureSource(tag: "feed:device:a:b") == .feed(.device(id: "a:b")) && CaptureSource(tag: "scene:s1") == .scene("s1") && CaptureSource(tag: "x") == nil)
        #expect(CaptureSource(tag: CaptureSource.feed(.camera).tag) == .feed(.camera))
    }
}

// MARK: - status strip

@Suite struct CaptureStatusStripTests {
    @Test func mapping() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        let locked = MatchControl(state: .locked, unlocksAt: iso.string(from: now.addingTimeInterval(751)), reason: "Registration open")
        var auto = LiveAutoCapture(active: true, lastCaptureAt: now.addingTimeInterval(-12), lastError: "Couldn't read frame", paused: true, lastDetected: "lobby")
        var st = CaptureStatusStrip.make(control: locked, auto: auto, localLastAt: nil, localDetected: nil, now: now)
        #expect(st.state == "Locked · unlocks in 12:31" && st.stateTone == .warn)
        #expect(st.lastShot == "Last screenshot 12 s ago · Lobby" && st.error == "Couldn't read frame" && st.pausedByManager)
        auto.paused = false; auto.lastError = nil; auto.lastDetected = nil
        st = CaptureStatusStrip.make(control: MatchControl(state: .live), auto: auto, localLastAt: now.addingTimeInterval(-2), localDetected: "in_game", now: now)
        #expect(st.state == "Live" && st.stateTone == .live && st.lastShot == "Last screenshot just now · In-game" && st.error == nil && !st.pausedByManager)
        st = CaptureStatusStrip.make(control: nil, auto: nil, localLastAt: nil, localDetected: nil, now: now)
        #expect(st.lastShot == nil && st.stateTone == .neutral)
        #expect(CaptureStatusStrip.make(control: MatchControl(state: .ended), auto: nil, localLastAt: now.addingTimeInterval(-200), localDetected: "results", now: now).lastShot == "Last screenshot 3 min ago · Results")
        #expect(CaptureStatusStrip.make(control: MatchControl(state: .published), auto: nil, localLastAt: nil, localDetected: nil, now: now).state == "Published")
    }
}


@Suite @MainActor struct CaptureCadenceTests {
    @Test func firstFrameAfterTheIntervalThenExactlyEveryInterval() async {
        let f = FakeStudio()
        let s = AutoCaptureSession(interval: 15, env: f.env())
        #expect(s.start(now: f.now))
        #expect(s.nextDueAt == f.now.addingTimeInterval(15))                 // 15 s picked: first send at +15 s
        f.now = f.now.addingTimeInterval(14.9); s.pump(now: f.now); await s.currentTask?.value
        #expect(f.mock.uploads.isEmpty)
        let start = f.now.addingTimeInterval(0.1)
        f.now = start; s.pump(now: f.now); await s.currentTask?.value
        #expect(f.mock.uploads.count == 1)
        // a slow answer doesn't push the schedule: still due 15 s after the previous due time
        #expect(s.nextDueAt == start.addingTimeInterval(15))
    }
    @Test func serverMayOnlySlowDown() async {
        let f = FakeStudio()
        let s = AutoCaptureSession(interval: 15, env: f.env())
        f.mock.captureReply = .accepted(captureId: "c", queuePosition: 0, nextIntervalSeconds: 5)
        s.start(now: f.now.addingTimeInterval(-15)); s.pump(now: f.now); await s.currentTask?.value
        #expect(s.effectiveInterval == 15)                                   // server said 5: operator's 15 wins
        f.mock.captureReply = .accepted(captureId: "c", queuePosition: 0, nextIntervalSeconds: 30)
        f.now = s.nextDueAt!; s.pump(now: f.now); await s.currentTask?.value
        #expect(s.effectiveInterval == 30)                                   // server may slow down
    }
}

// MARK: start-with-match: lobby from start time + 30 s, through the results, until AirBattleground has them all

@Suite(.serialized) @MainActor struct CaptureFollowMatchTests {
    @Test func armsThePickedMatchAndStartsThirtySecondsAfterItsStartTime() {
        let f = FakeStudio()
        f.control = .ready
        let start = f.now.addingTimeInterval(60)
        var env = f.env()
        env.startsAt = { start }
        let c = AutoCaptureController(env: env, startLoop: false)
        c.followMatch()
        #expect(c.armed && !c.live.running)
        f.now = start.addingTimeInterval(29); c.followMatch()
        #expect(c.armed && !c.live.running)
        f.now = start.addingTimeInterval(30); c.followMatch()
        #expect(!c.armed && c.live.running)
        // the match ends: capture keeps going (results screens) until the server says every result is in
        f.control = .ended; c.followMatch()
        #expect(c.live.running)
        c.live.apply(.finished("All results are in"))
        #expect(!c.live.running && c.live.finished && !c.live.isError && c.live.statusLine.hasPrefix("All results are in"))
    }
    @Test func publishedOrLongEndedStopsAndTheNextMatchIsArmed() {
        let f = FakeStudio()
        f.control = .live
        let c = AutoCaptureController(env: f.env(), startLoop: false)
        c.followMatch(); #expect(c.live.running)
        f.control = .ended; c.followMatch()
        f.now = f.now.addingTimeInterval(AutoCaptureController.endedTimeout + 1); c.followMatch()
        #expect(!c.live.running)
        f.matchId = "m2"; f.control = .live; c.followMatch()
        #expect(c.live.running)
        f.control = .published; c.followMatch()
        #expect(!c.live.running)
    }
}

@Suite struct MatchProcessingTests {
    @Test func endedWithoutEveryResultStaysOnGameplayAndSaysProcessing() throws {
        let json = #"{"match":{"state":"summary"},"control":{"state":"ended"},"results":{"complete":false,"placed":3,"teams":16}}"#
        let s = try MatchDataParser.parse(Data(json.utf8))
        #expect(s.processing && s.stage == .gameplay)
        #expect(MatchDataParser.variables(s, now: Date())[MatchKeys.processing] == "PROCESSING RESULTS")
        let done = try MatchDataParser.parse(Data(json.replacingOccurrences(of: #""complete":false"#, with: #""complete":true"#).utf8))
        #expect(!done.processing && done.stage == .summary)
        #expect(MatchDataParser.variables(done, now: Date())[MatchKeys.processing] == "")
        // older servers send no `results`: unchanged
        let legacy = try MatchDataParser.parse(Data(#"{"match":{"state":"summary"},"control":{"state":"ended"}}"#.utf8))
        #expect(!legacy.processing && legacy.stage == .summary)
    }
}
