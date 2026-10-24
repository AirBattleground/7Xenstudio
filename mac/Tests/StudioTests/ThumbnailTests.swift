import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Studio

// MARK: helpers

private func thumbPNG(_ img: CGImage, _ path: String) {
    guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}
private func downscale(_ img: CGImage, _ w: Int, _ h: Int) -> CGImage? {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    c?.interpolationQuality = .high
    c?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return c?.makeImage()
}
/// Random-noise image (incompressible) for the size cap.
private func noise(_ w: Int, _ h: Int) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    var x: UInt32 = 2463534242
    for i in 0..<bytes.count { x ^= x << 13; x ^= x >> 17; x ^= x << 5; bytes[i] = UInt8(truncatingIfNeeded: x) }
    let c = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return c.makeImage()!
}
private func solid(_ w: Int, _ h: Int) -> CGImage {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.setFillColor(CGColor(srgbRed: 0.8, green: 0.6, blue: 0.2, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return c.makeImage()!
}
private func boundary(_ contentType: String?) -> String? {
    contentType?.components(separatedBy: "boundary=").last
}
private func allThumbnailKeys() -> Set<String> {
    var s: Set<String> = [MatchKeys.matchTitle, MatchKeys.map, MatchKeys.matchNumber, MatchKeys.round, MatchKeys.startsAt, MatchKeys.startsAtLocal,
                          MatchKeys.matchLine, MatchKeys.countdown, MatchKeys.teamCount, MatchKeys.aliveTeams, MatchKeys.elapsed, MatchKeys.matchState]
    s.formUnion([MatchKeys.mvpName, MatchKeys.mvpTeam, MatchKeys.winnerName, MatchKeys.preparing, MatchKeys.countdownGhost, MatchKeys.countdownLabel])
    return s
}
/// Every {{key}} in a scene's text layers (groups included).
private func bindings(_ s: LayerScene) -> Set<String> {
    var out = Set<String>()
    s.forEachLayer { l in
        guard case .text(let t) = l.kind else { return }
        var rest = Substring(t.string)
        while let o = rest.range(of: "{{"), let c = rest.range(of: "}}", range: o.upperBound..<rest.endIndex) {
            out.insert(rest[o.upperBound..<c.lowerBound].trimmingCharacters(in: .whitespaces)); rest = rest[c.upperBound...]
        }
    }
    return out
}
@MainActor private func makeController(mock: MockBroadcastLinkService, scenes: [LayerScene] = [AdvancedStudioPreset.youtubeThumbnail()],
                                       broadcast: String? = "b1", persistence: ThumbnailPersistence? = nil) -> ThumbnailController {
    let env = ThumbnailEnvironment(scenes: { scenes }, variables: { SceneVariables(MatchKeys.sample) },
                                   render: { _, size, _, _, _ in solid(Int(size.width), Int(size.height)) },
                                   upload: { u in await mock.uploadThumbnail(u) },
                                   broadcastId: { broadcast }, matchId: { "m1" })
    let c = ThumbnailController(env: env, persistence: persistence)
    c.retryDelay = 0
    return c
}

// MARK: image

@Suite struct ThumbnailImageTests {
    @Test func encodesExactly1280x720JPEG() throws {
        for (w, h) in [(1280, 720), (1920, 1080), (800, 800), (3000, 1000), (640, 360)] {
            let d = try #require(ThumbnailImage.encode(solid(w, h)))
            let sz = try #require(ThumbnailImage.pixelSize(d))
            #expect(sz.w == 1280 && sz.h == 720)
            #expect(d.count <= ThumbnailImage.maxBytes)
            #expect(d.starts(with: [0xFF, 0xD8, 0xFF]))                       // JPEG SOI
            let src = try #require(CGImageSourceCreateWithData(d as CFData, nil))
            #expect(CGImageSourceGetType(src) as String? == UTType.jpeg.identifier)
            let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
            #expect((img.colorSpace?.name as String?) == (CGColorSpace.sRGB as String))
        }
    }
    @Test func qualityStepsDownUntilUnderTheCap() throws {
        let n = noise(1280, 720)
        let best = try #require(ThumbnailImage.jpeg(n, quality: ThumbnailImage.qualities[0]))
        let cap = best.count * 2 / 3                                       // forces at least one step down
        let d = try #require(ThumbnailImage.encode(n, maxBytes: cap))
        #expect(d.count <= cap && d.count < best.count)
        #expect(ThumbnailImage.encode(n, maxBytes: 1000) == nil)           // can't fit: refused, never oversized
        // real cap: noise at 1280x720 still fits 2 MB
        let real = try #require(ThumbnailImage.encode(n))
        #expect(real.count <= 2 * 1024 * 1024)
    }
    @Test func uploadedFilesAreNormalised() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("square.png")
        thumbPNG(solid(1000, 1000), url.path)
        let d = try #require(ThumbnailImage.encodeFile(url))
        #expect(ThumbnailImage.pixelSize(d)! == (1280, 720))
        #expect(ThumbnailImage.encodeFile(dir.appendingPathComponent("missing.png")) == nil)
    }
}

// MARK: wire

@Suite struct ThumbnailWireTests {
    let host = "https://thumb.test"

    @Test func multipartFormat() throws {
        let client = StudioLinkClient(host: host, key: "sw_secret")
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0xFF, 0xD9])
        let u = ThumbnailUpload(broadcastId: "b 1/x", matchId: "m42", image: jpeg)
        let r = try client.thumbnailRequest(u, boundary: "BOUNDARY")
        #expect(r.httpMethod == "POST")
        #expect(r.url?.absoluteString == "https://thumb.test/api/studio-link/broadcasts/b%201%2Fx/thumbnail")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUNDARY")
        #expect(r.value(forHTTPHeaderField: "X-Studio-Key") == "sw_secret")
        var expected = Data("--BOUNDARY\r\nContent-Disposition: form-data; name=\"matchId\"\r\n\r\nm42\r\n".utf8)
        expected.append(Data("--BOUNDARY\r\nContent-Disposition: form-data; name=\"file\"; filename=\"thumbnail.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        expected.append(jpeg); expected.append(Data("\r\n--BOUNDARY--\r\n".utf8))
        #expect(r.httpBody == expected)
        // no match: no matchId part
        let body = try client.thumbnailRequest(ThumbnailUpload(broadcastId: "b1", matchId: nil, image: jpeg), boundary: "B").httpBody!
        #expect(!String(decoding: body, as: UTF8.self).contains("matchId"))
        #expect(ThumbnailUpload(broadcastId: "b", matchId: nil, image: jpeg, contentType: "image/png").filename == "thumbnail.png")
    }

    @Test func uploadOverTheWire() async throws {
        let session = ABGStub.session(host: "thumb-wire.test") { seen in
            seen.path.hasSuffix("/thumbnail") ? (200, #"{"ok":true,"url":"https://i.ytimg.com/vi/abc/maxresdefault.jpg"}"#) : nil
        }
        let client = StudioLinkClient(host: "https://thumb-wire.test", key: "sw_k", session: session)
        let jpeg = ThumbnailImage.encode(solid(1280, 720))!
        let reply = await client.uploadThumbnail(ThumbnailUpload(broadcastId: "b9", matchId: "m1", image: jpeg))
        #expect(reply == .set(url: "https://i.ytimg.com/vi/abc/maxresdefault.jpg"))
        let seen = try #require(ABGStub.requests("thumb-wire.test").first)
        #expect(seen.path == "/api/studio-link/broadcasts/b9/thumbnail" && seen.key == "sw_k")
        let b = try #require(boundary(seen.contentType))
        let text = String(decoding: seen.body ?? Data(), as: UTF8.self)
        #expect(text.hasPrefix("--\(b)\r\n") && text.contains("name=\"file\"; filename=\"thumbnail.jpg\"") && text.contains("Content-Type: image/jpeg"))
        #expect((seen.body ?? Data()).range(of: jpeg) != nil)
    }

    @Test func transportFailureIsUnreachable() async {
        let session = ABGStub.session(host: "thumb-down.test") { _ in nil }
        let client = StudioLinkClient(host: "https://thumb-down.test", key: "k", session: session)
        #expect(await client.uploadThumbnail(ThumbnailUpload(broadcastId: "b", matchId: nil, image: Data([1]))) == .unreachable)
    }

    @Test func responsesAndErrors() {
        func r(_ s: Int, _ body: String = "", retry: String? = nil) -> ThumbnailReply { ThumbnailReply.from(status: s, body: Data(body.utf8), retryAfter: retry) }
        #expect(r(200, #"{"ok":true,"url":"https://i.ytimg.com/x.jpg"}"#) == .set(url: "https://i.ytimg.com/x.jpg"))
        #expect(r(200, "") == .set(url: nil))
        let notAllowed = r(403, #"{"error":{"code":"THUMBNAIL_NOT_ALLOWED","message":"Verify the channel to use custom thumbnails."}}"#)
        #expect(notAllowed == .notAllowed("Verify the channel to use custom thumbnails."))
        #expect(notAllowed.message == "Verify the channel to use custom thumbnails." && !notAllowed.isRetryable)
        #expect(r(403, #"{"error":{"code":"FORBIDDEN","message":"no"}}"#) == .keyRejected)
        #expect(r(401) == .keyRejected)
        #expect(r(409, #"{"error":{"code":"BROADCAST_ENDED","message":"The broadcast has ended."}}"#) == .notReady("The broadcast has ended."))
        #expect(r(413) == .tooLarge)
        #expect(r(429, retry: "30") == .rateLimited(retryAfter: 30))
        #expect(r(429, retry: "30").message.contains("30 s"))
        let unsupported = r(501, #"{"error":{"code":"NOT_IMPLEMENTED","message":"x"}}"#)
        #expect(unsupported == .unsupported && !unsupported.isRetryable)
        #expect(unsupported.message == "AirBattleground doesn't support thumbnails yet")
        #expect(r(500).isRetryable && r(502).isRetryable && r(503, #"{"error":{"message":"down"}}"#) == .serverError(503, "down"))
        #expect(ThumbnailReply.unreachable.isRetryable)
        #expect(!r(400).isRetryable && !r(404).isRetryable && !r(409).isRetryable && !r(413).isRetryable && !r(429).isRetryable)
    }
}

// MARK: controller

@Suite @MainActor struct ThumbnailFlowTests {
    @Test func autoUploadAfterGoLive() async throws {
        let mock = MockBroadcastLinkService(account: ABGAccount(name: "A", org: nil))
        let abg = ABGController(service: mock, startPresence: false)
        abg.select(mock.matchList[0])
        let thumb = makeController(mock: mock)
        // the AppModel sequence: open broadcast -> stream -> heartbeats -> thumbnail once
        let ingest = try await abg.prepareYouTube()
        thumb.broadcastStarted(id: ingest.broadcastId, matchId: abg.link?.eventId)
        await thumb.autoTask?.value
        #expect(mock.calls.filter { $0.hasPrefix("thumbnail:") } == ["thumbnail:b1"])
        let start = try #require(mock.calls.firstIndex(of: "start")), up = try #require(mock.calls.firstIndex(of: "thumbnail:b1"))
        #expect(start < up)
        let u = try #require(mock.thumbnails.first)
        #expect(u.matchId == "m1" && u.contentType == "image/jpeg" && u.image.count <= ThumbnailImage.maxBytes)
        #expect(ThumbnailImage.pixelSize(u.image)! == (1280, 720))
        if case .set(let url, _) = thumb.status { #expect(url == "https://i.ytimg.com/vi/mock/maxresdefault.jpg") } else { Issue.record("status \(thumb.status)") }
        #expect(thumb.status.text == "Thumbnail set ✓")
    }
    @Test func autoOffUploadsNothing() async {
        let mock = MockBroadcastLinkService()
        let thumb = makeController(mock: mock)
        thumb.settings.autoSet = false
        thumb.broadcastStarted(id: "b1", matchId: nil)
        #expect(thumb.autoTask == nil)
        #expect(mock.thumbnails.isEmpty)
    }
    @Test func retriesOnlyServerErrorsAndTimeouts() async {
        let mock = MockBroadcastLinkService()
        mock.thumbnailReplies = [.serverError(502, nil), .unreachable, .serverError(500, nil)]
        let thumb = makeController(mock: mock)
        let r = await thumb.upload(broadcastId: "b1", matchId: nil)
        #expect(r?.isSuccess == true && mock.thumbnails.count == 4)        // 1 + 3 retries
        // gives up after 3 retries
        mock.thumbnailReplies = Array(repeating: .serverError(503, "busy"), count: 6)
        let r2 = await thumb.upload(broadcastId: "b1", matchId: nil)
        #expect(r2 == .serverError(503, "busy") && mock.thumbnails.count == 8)
        #expect(thumb.status == .failed("AirBattleground: busy"))
    }
    @Test func unsupportedAndNotAllowedAreNotRetried() async {
        let mock = MockBroadcastLinkService()
        let thumb = makeController(mock: mock)
        mock.thumbnailReplies = [.unsupported]
        _ = await thumb.upload(broadcastId: "b1", matchId: nil)
        #expect(mock.thumbnails.count == 1 && thumb.status == .unsupported)
        #expect(thumb.status.text == "AirBattleground doesn't support thumbnails yet")
        mock.thumbnailReplies = [.notAllowed("Channel not verified")]
        _ = await thumb.upload(broadcastId: "b1", matchId: nil)
        #expect(mock.thumbnails.count == 2 && thumb.status == .failed("Channel not verified"))
        for reply in [ThumbnailReply.notReady(nil), .tooLarge, .rateLimited(retryAfter: 5), .badRequest(nil)] {
            mock.thumbnailReplies = [reply]
            let before = mock.thumbnails.count
            _ = await thumb.upload(broadcastId: "b1", matchId: nil)
            #expect(mock.thumbnails.count == before + 1)
        }
    }
    @Test func updateNowNeedsABroadcast() async {
        let mock = MockBroadcastLinkService()
        let off = makeController(mock: mock, broadcast: nil)
        #expect(await off.updateNow() == nil && mock.thumbnails.isEmpty && !off.isLive)
        let on = makeController(mock: mock, broadcast: "b7")
        #expect(await on.updateNow() == .set(url: "https://i.ytimg.com/vi/mock/maxresdefault.jpg"))
        #expect(mock.thumbnails.first?.broadcastId == "b7" && mock.thumbnails.first?.matchId == "m1")
    }
    @Test func sourcesAndSettings() async throws {
        let mock = MockBroadcastLinkService()
        let other = LayerScene(id: "s2", name: "Other", layers: [.text("T", "{{matchTitle}}", x: 0, y: 0, w: 100, h: 50)])
        let p = ThumbnailMemoryPersistence()
        let thumb = makeController(mock: mock, scenes: [other], persistence: p)
        #expect(p.settings == ThumbnailSettings() && thumb.settings.autoSet && thumb.settings.source == .builtin)
        // the built-in thumbnail scene works even when the operator deleted it (fresh copy)
        #expect(thumb.scene(for: .builtin)?.id == AdvancedStudioPreset.thumbnailId)
        #expect(thumb.scene(for: .scene("s2"))?.id == "s2")
        #expect(thumb.scene(for: .scene("gone"))?.id == AdvancedStudioPreset.thumbnailId)
        thumb.settings.source = .scene("s2")
        #expect(p.settings.source == .scene("s2") && thumb.sourceTitle == "Other")
        await thumb.refreshPreview()
        #expect(thumb.preview?.width == 1280 && thumb.preview?.height == 720)
        // file source: a missing file fails cleanly
        thumb.useFile(URL(fileURLWithPath: "/nonexistent/x.png"))
        await thumb.refreshPreview()
        #expect(thumb.preview == nil && thumb.previewError != nil)
        #expect(await thumb.upload(broadcastId: "b1", matchId: nil) == nil && mock.thumbnails.isEmpty)
        // settings round trip + lenient decoding
        let s = ThumbnailSettings(source: .file("/a/b.png"), autoSet: false)
        #expect(try JSONDecoder().decode(ThumbnailSettings.self, from: JSONEncoder().encode(s)) == s)
        #expect(try JSONDecoder().decode(ThumbnailSettings.self, from: Data(#"{"source":42}"#.utf8)) == ThumbnailSettings())
    }
}

// MARK: scene + seeding

@Suite struct ThumbnailSceneTests {
    @Test func sceneUsesOnlyMatchKeys() {
        let s = AdvancedStudioPreset.youtubeThumbnail()
        #expect(s.id == AdvancedStudioPreset.thumbnailId && s.name == "YouTube Thumbnail")
        #expect(s.canvas.w * 9 == s.canvas.h * 16)
        let keys = bindings(s)
        #expect(keys.isSubset(of: allThumbnailKeys()))
        #expect(keys.isSuperset(of: [MatchKeys.matchTitle, MatchKeys.matchLine, MatchKeys.startsAtLocal]))
        // the image assets it uses exist
        s.forEachLayer { l in if case .image(let i) = l.kind, let b = i.builtin { #expect(BuiltinAssets.asset(b) != nil, "missing \(b)") } }
        // never part of the match journey
        #expect(!AdvancedStudioPreset.makeScenes().values.contains { $0.id == s.id })
    }
    @Test func titleDashStaysOnLineOne() {
        let v = ThumbnailController.prepare(SceneVariables([MatchKeys.matchTitle: "GRAND FINALS - MATCH 3", MatchKeys.map: "A - B"]))
        #expect(v[MatchKeys.matchTitle] == "GRAND FINALS\u{00A0}- MATCH 3")
        #expect(v[MatchKeys.map] == "A - B")
    }
    @Test func startsAtLocalAndMatchLine() {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 24; c.hour = 19; c.minute = 30
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")
        let d = Calendar(identifier: .gregorian).date(from: c)!
        #expect(MatchKeys.localStart(d, timeZone: TimeZone(identifier: "Asia/Kolkata")!) == "SAT 24 OCT · 7:30 PM")
        #expect(MatchKeys.line(round: "Grand Finals", matchNumber: "3", map: "Erangel") == "Grand Finals · MATCH 3 · Erangel")
        #expect(MatchKeys.line(round: nil, matchNumber: "3", map: " ") == "MATCH 3")
        #expect(MatchKeys.line(round: nil, matchNumber: nil, map: nil) == "")
        // the feed fills them
        var snap = MatchSnapshot(); snap.round = "Grand Finals"; snap.matchNumber = "3"; snap.map = "Erangel"; snap.startsAt = d
        let v = MatchDataParser.variables(snap, now: d)
        #expect(v[MatchKeys.matchLine] == "Grand Finals · MATCH 3 · Erangel")
        #expect(v[MatchKeys.startsAtLocal] == MatchKeys.localStart(d))
    }
    @Test func seededOnceForNewAndExistingStoresAndRespectsDeletion() throws {
        let thumb = AdvancedStudioPreset.youtubeThumbnail()
        var stages: [JourneyStage: LayerScene] = [:]
        for s in JourneyStage.allCases { stages[s] = LayerScene(id: "adv.\(s.rawValue)", name: s.title, layers: [.text("T", "x", x: 0, y: 0, w: 1, h: 1)]) }
        // existing store: Advanced already seeded before the thumbnail existed
        var b = PresetBook()
        b.migrate(scenes: [])
        _ = b.seedAdvanced(stages: stages, extras: [])
        let added = b.seedAdvancedAdditions([thumb])
        #expect(added.map(\.id) == [thumb.id])
        var adv = try #require(b.presets.first { $0.builtin == StudioPreset.builtinAdvanced })
        #expect(adv.sceneIds.last == thumb.id && adv.journey.values.contains(thumb.id) == false)
        #expect(b.seedAdvancedAdditions([thumb]).isEmpty)                          // once
        b.sceneDeleted(thumb.id)
        #expect(b.seedAdvancedAdditions([thumb]).isEmpty)                          // the operator deleted it: stays deleted
        adv = try #require(b.presets.first { $0.builtin == StudioPreset.builtinAdvanced })
        #expect(!adv.sceneIds.contains(thumb.id))
        // never into an unseeded Advanced preset
        var fresh = PresetBook(); fresh.migrate(scenes: [])
        #expect(fresh.seedAdvancedAdditions([thumb]).isEmpty)
        // Codable round trip keeps the marker
        let data = try JSONEncoder().encode(b.presets)
        #expect(try JSONDecoder().decode([StudioPreset].self, from: data) == b.presets)
    }
    @Test func storeSeedsTheThumbnailScene() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-store-\(UUID().uuidString)")
        let thumb = AdvancedStudioPreset.youtubeThumbnail()
        let stages = AdvancedStudioPreset.makeScenes()
        let store = try StudioStore(dir: dir)
        store.ensurePresets(advancedStages: stages, advancedExtras: AdvancedStudioPreset.extraScenes(), advancedAdditions: [thumb])
        #expect(store.snapshot.layerScenes.contains { $0.id == thumb.id })
        // the operator deletes it: a relaunch doesn't bring it back
        store.update { doc in doc.layerScenes.removeAll { $0.id == thumb.id } }
        let again = try StudioStore(dir: dir)
        let b = again.ensurePresets(advancedStages: stages, advancedExtras: AdvancedStudioPreset.extraScenes(), advancedAdditions: [thumb])
        #expect(!again.snapshot.layerScenes.contains { $0.id == thumb.id })
        #expect(!(b.presets.first { $0.builtin == StudioPreset.builtinAdvanced }?.sceneIds.contains(thumb.id) ?? true))
    }
}

// MARK: shots

/// Dev: THUMB_SHOTS=1 renders the thumbnail (sample data, a long title, no data) at 1280x720 and 168x94 into /tmp/thumb-shots.
@Suite struct ThumbnailShots {
    @Test func renderShots() throws {
        guard ProcessInfo.processInfo.environment["THUMB_SHOTS"] != nil else { return }
        try FileManager.default.createDirectory(atPath: "/tmp/thumb-shots", withIntermediateDirectories: true)
        let engine = StudioEngine()
        let scene = AdvancedStudioPreset.youtubeThumbnail()
        var long = MatchKeys.sample
        long[MatchKeys.matchTitle] = "BGMI PRO SERIES SEASON 4 GRAND FINALS - DAY 3 MATCH 12 FINAL SHOWDOWN"
        long[MatchKeys.matchLine] = "GRAND FINALS · MATCH 12 · MIRAMAR"
        var short = MatchKeys.sample
        short[MatchKeys.matchTitle] = "SCRIM 7"
        for (name, vars) in [("sample", MatchKeys.sample), ("long", long), ("short", short), ("empty", [:])] {
            let img = try #require(engine.renderStill(scene, size: ThumbnailImage.size, variables: ThumbnailController.prepare(SceneVariables(vars)), time: 4))
            let jpeg = try #require(ThumbnailImage.encode(img))
            try jpeg.write(to: URL(fileURLWithPath: "/tmp/thumb-shots/\(name).jpg"))
            thumbPNG(img, "/tmp/thumb-shots/\(name)-1280.png")
            if let s = downscale(img, 168, 94) { thumbPNG(s, "/tmp/thumb-shots/\(name)-168.png") }
            if let s = downscale(img, 168, 94), let up = downscale(s, 504, 282) { thumbPNG(up, "/tmp/thumb-shots/\(name)-168x3.png") }
            print("thumb \(name): \(jpeg.count) bytes")
        }
    }
}

#if canImport(AppKit)
import AppKit
import SwiftUI
/// Dev: THUMB_SHOTS=1 also snapshots the Outputs panel and the Go Live sheet (mock backend) into /tmp/thumb-shots.
@Suite @MainActor struct ThumbnailUIShots {
    @Test func panelShots() async throws {
        guard ProcessInfo.processInfo.environment["THUMB_SHOTS"] != nil else { return }
        try FileManager.default.createDirectory(atPath: "/tmp/thumb-shots", withIntermediateDirectories: true)
        setenv("STUDIO_ABG_MOCK", "1", 1)                     // mock AirBattleground (never the keychain / real server)
        let model = AppModel(services: MockServices())
        unsetenv("STUDIO_ABG_MOCK")
        await model.abg.refreshMatches()
        if let m = model.abg.matches.first { model.abg.select(m) }
        await model.thumbnail.refreshPreview()
        func snap<V: View>(_ v: V, _ size: CGSize, _ name: String) {
            let host = NSHostingView(rootView: v.environment(model).preferredColorScheme(.dark).background(Theme.bg))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let cg = rep.cgImage { thumbPNG(cg, "/tmp/thumb-shots/ui-\(name).png") }
        }
        snap(ThumbnailPanel().frame(width: 520).padding(), CGSize(width: 560, height: 260), "outputs-panel")
        snap(GoLiveSheet(), CGSize(width: 520, height: 600), "golive-sheet")
    }
}
#endif
