import Testing
import Foundation
@testable import Studio

private func tmpDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("studio-test-\(UUID().uuidString)")
    return u
}

@Suite struct StoreTests {
    @Test func persistsAndReloads() throws {
        let dir = tmpDir()
        let s = try StudioStore(dir: dir)
        s.upsert(Destination(id: "x", name: "YT", kind: .youtube, url: "rtmp://a", key: "k"))
        let show = s.createShow(name: "Night")
        let s2 = try StudioStore(dir: dir)
        #expect(s2.destinations.count == 1 && s2.destinations[0].key == "k")
        #expect(s2.shows.first?.id == show.id && s2.shows.first?.scenes.count == 4)
        #expect(s2.secret == s.secret && s.secret.count == 32)
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("secret").path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }
    @Test func keysAreStoredHashed() throws {
        let dir = tmpDir()
        let s = try StudioStore(dir: dir)
        let tokens = Tokens(secret: s.secret)
        let dm = DeviceManager(store: s, tokens: tokens)
        let (dev, key, pair) = try dm.create(name: "Phone A")
        let json = try String(contentsOf: dir.appendingPathComponent("store.json"), encoding: .utf8)
        #expect(!json.contains(key))
        #expect(s.device(byKey: key)?.id == dev.id)
        #expect(key.hasPrefix("7xk_") && dev.id.count == 24 && pair.hasPrefix("7xen://pair?host="))
        #expect(throws: APIError.self) { try dm.create(name: "x") }
    }
    @Test func helpers() {
        #expect(slugify("Café Night Show!") == "cafe-night-show")
        #expect(slugify("!!!") == "show")
        #expect(joinStreamKey("rtmp://a/live2/", " /abc ") == "rtmp://a/live2/abc")
    }
}

@Suite struct TokenTests {
    let tokens = Tokens(secret: Data(repeating: 7, count: 32))
    @Test func publishTokenRoundTrip() {
        let now = Date()
        let (t, exp) = tokens.publishToken(deviceId: "d1", keyHash: "h", now: now)
        #expect(abs(exp.timeIntervalSince(now) - 600) < 0.01)
        #expect(tokens.verifyPublishToken(deviceId: "d1", keyHash: "h", token: t, now: now))
        #expect(!tokens.verifyPublishToken(deviceId: "d2", keyHash: "h", token: t, now: now))
        #expect(!tokens.verifyPublishToken(deviceId: "d1", keyHash: "other", token: t, now: now))
        #expect(!tokens.verifyPublishToken(deviceId: "d1", keyHash: "h", token: t, now: now.addingTimeInterval(601)))
        #expect(!tokens.verifyPublishToken(deviceId: "d1", keyHash: "h", token: "1.2.3", now: now))
    }
    @Test func internalCreds() {
        #expect(tokens.isInternal(user: "studio", password: tokens.internalPass))
        #expect(!tokens.isInternal(user: "studio", password: "nope"))
        #expect(Tokens(secret: Data(repeating: 8, count: 32)).internalPass != tokens.internalPass)
    }
}

@Suite struct RoutingTests {
    func setup() throws -> (StudioRouter, DeviceManager, StoredDevice, String, Tokens) {
        let s = try StudioStore(dir: tmpDir())
        let t = Tokens(secret: s.secret)
        let dm = DeviceManager(store: s, tokens: t, lanHost: "10.0.0.5")
        let (d, k, _) = try dm.create(name: "Phone A")
        return (StudioRouter(store: s, devices: dm, tokens: t), dm, d, k, t)
    }
    func req(_ path: String, key: String? = nil, body: String = "{}", ip: String = "10.0.0.9", method: String = "POST") -> HTTPRequest {
        var h: [String: String] = [:]; if let key { h["x-device-key"] = key }
        return HTTPRequest(method: method, path: path, headers: h, body: Data(body.utf8), remoteIP: ip)
    }
    func obj(_ r: HTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:] }

    @Test func badKeyIs401() async throws {
        let (r, _, _, _, _) = try setup()
        let res = await r.handle(req("/api/device/hello", key: "7xk_wrong"))
        #expect(res.status == 401)
        #expect((obj(res)["error"] as? [String: Any])?["code"] as? String == "DEVICE_KEY_INVALID")
    }
    @Test func helloHeartbeatStream() async throws {
        let (r, dm, d, k, t) = try setup()
        let h = await r.handle(req("/api/device/hello", key: k, body: #"{"deviceModel":"iPhone15","appVersion":"1.0"}"#))
        #expect(h.status == 200)
        #expect((obj(h)["device"] as? [String: Any])?["id"] as? String == d.id)
        #expect(dm.store.device(d.id)?.model == "iPhone15")
        let hb = await r.handle(req("/api/device/heartbeat", key: k, body: #"{"state":"LIVE","battery":0.5}"#))
        #expect(hb.status == 200 && (obj(hb)["snapshotRequests"] as? [Any])?.isEmpty == true)
        let bad = await r.handle(req("/api/device/heartbeat", key: k, body: #"{"battery":3}"#))
        #expect(bad.status == 400)
        let st = await dm.status(d)
        #expect(st.online && st.streaming && st.battery == 0.5)
        let ss = await r.handle(req("/api/device/stream/start", key: k, body: #"{"quality":"1080p","fps":60}"#))
        let o = obj(ss)
        #expect(o["rtmpUrl"] as? String == "rtmp://10.0.0.5:1940/live")
        let name = o["streamName"] as! String
        #expect(name.hasPrefix("dev_\(d.id)?token="))
        let q = String(name.split(separator: "?")[1])
        #expect(authorizeMedia(MediaAuthRequest(ip: "10.0.0.9", action: "publish", path: "live/dev_\(d.id)", query: q), tokens: t, deviceKeyHash: { dm.store.device($0)?.keyHash }))
        #expect(await r.handle(req("/api/device/stream/start", key: k, body: #"{"quality":"4k"}"#)).status == 400)
        #expect(await r.handle(req("/api/device/stream/stop", key: k)).status == 204)
        #expect(await r.handle(req("/api/device/nope", key: k)).status == 404)
        #expect(await r.handle(req("/api/device/hello", key: k, method: "GET")).status == 404)
    }
    @Test func mediaAuthHook() async throws {
        let (r, dm, d, _, t) = try setup()
        func post(_ json: String, ip: String = "127.0.0.1") async -> Int { await r.handle(req("/internal/media/auth", body: json, ip: ip)).status }
        #expect(await post(#"{"action":"read","path":"live/dev_\#(d.id)","ip":"127.0.0.1"}"#) == 200)
        #expect(await post(#"{"action":"read","path":"live/dev_\#(d.id)","ip":"10.0.0.9"}"#) == 401)
        #expect(await post(#"{"action":"publish","path":"live/dev_\#(d.id)","ip":"10.0.0.9","query":"token=bad"}"#) == 401)
        let tok = t.publishToken(deviceId: d.id, keyHash: d.keyHash).token
        #expect(await post(#"{"action":"publish","path":"live/dev_\#(d.id)","ip":"10.0.0.9","query":"token=\#(tok)"}"#) == 200)
        #expect(await post(#"{"action":"publish","path":"live/show_abcdefgh12","ip":"127.0.0.1"}"#) == 200)
        #expect(await post(#"{"action":"publish","path":"live/show_abcdefgh12","ip":"10.0.0.9"}"#) == 401)
        #expect(await post(#"{"user":"studio","password":"\#(t.internalPass)","action":"api","ip":"127.0.0.1"}"#) == 200)
        // the hook is loopback-only
        #expect(await post("{}", ip: "10.0.0.9") == 404)
        try await dm.remove(d.id)
        #expect(await post(#"{"action":"publish","path":"live/dev_\#(d.id)","ip":"10.0.0.9","query":"token=\#(tok)"}"#) == 401)
    }
    @Test func snapshotUpload() async throws {
        let (r, dm, d, k, _) = try setup()
        async let png = dm.requestSnapshot(d.id, wait: 3)
        try await Task.sleep(nanoseconds: 200_000_000)
        let hb = await r.handle(req("/api/device/heartbeat", key: k))
        let id = ((obj(hb)["snapshotRequests"] as? [[String: Any]])?.first?["id"]) as! String
        var body = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0, 1, 2])
        var rq = req("/api/device/snapshots/\(id)", key: k); rq.body = body; rq.headers["content-type"] = "image/png"
        #expect(await r.handle(rq).status == 204)
        #expect(await png == body)
        body = Data(); _ = body
        #expect(await r.handle(rq).status == 404)
    }
    @Test func httpParsing() {
        let raw = Data("POST /api/device/hello?x=1 HTTP/1.1\r\nHost: a\r\nX-Device-Key: k\r\nContent-Length: 2\r\n\r\n{}".utf8)
        guard case .complete(let q) = HTTPServer.parse(raw, ip: "1.2.3.4") else { Issue.record("not complete"); return }
        #expect(q.method == "POST" && q.path == "/api/device/hello" && q.query == "x=1" && q.header("X-Device-Key") == "k" && q.body.count == 2)
        guard case .needMore = HTTPServer.parse(raw.dropLast(), ip: "") else { Issue.record("expected needMore"); return }
    }
    @Test func rateLimit() {
        let l = RateLimiter(limit: 2, window: 60)
        #expect(l.allow("a") && l.allow("a") && !l.allow("a") && l.allow("b"))
    }
    @Test func liveServer() async throws {
        let (r, _, _, k, _) = try setup()
        let srv = HTTPServer(port: 44871) { await r.handle($0) }
        try srv.start(); defer { srv.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        var rq = URLRequest(url: URL(string: "http://127.0.0.1:44871/api/device/hello")!)
        rq.httpMethod = "POST"; rq.setValue(k, forHTTPHeaderField: "X-Device-Key"); rq.httpBody = Data("{}".utf8)
        let (data, resp) = try await URLSession.shared.data(for: rq)
        #expect((resp as! HTTPURLResponse).statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("assignedMatch"))
    }
}

@Suite(.serialized) struct OverlayStoreTests {
    @Test func overlaysPersistPerShow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ovstore-\(UUID().uuidString)")
        let a = try StudioStore(dir: dir); a.overlayDebounce = 0.05
        let show = a.ensureActiveShow()
        var o = Overlays(); o.logo.on = true; o.logo.propId = "p1"; o.logo.corner = .bl; o.web.url = "http://x/y.png"
        a.saveOverlays(o, forShow: show.id)
        #expect(a.overlays(forShow: show.id) == o)   // pending visible
        // debounced write: poll until it lands on disk instead of a fixed sleep
        let until = Date().addingTimeInterval(5)
        while Date() < until, (try? StudioStore(dir: dir))?.ensureActiveShow().overlays != o { Thread.sleep(forTimeInterval: 0.05) }
        let b = try StudioStore(dir: dir)
        let again = b.ensureActiveShow()
        #expect(again.id == show.id && again.overlays == o)
        o.liveBug = true; b.saveOverlays(o, forShow: show.id); b.flushOverlays()
        #expect(try StudioStore(dir: dir).ensureActiveShow().overlays.liveBug)
    }
}
