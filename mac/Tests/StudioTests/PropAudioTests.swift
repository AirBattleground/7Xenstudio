import Testing
import Foundation
@testable import Studio

/// A video prop with a soundtrack feeds its audio to the mixer callback (key "prop:<id>"), and restarts with the video.
@Suite(.serialized) struct PropAudioTests {
    @Test func videoPropSoundtrackReachesMixer() async throws {
        guard let ff = FFmpegLocator.locate() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("propaudio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mp4 = dir.appendingPathComponent("clip.mp4")
        let p = Process(); p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc=size=320x180:rate=30:duration=3", "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                       "-pix_fmt", "yuv420p", "-c:v", "libx264", "-c:a", "aac", "-shortest", "-y", mp4.path]
        try p.run(); p.waitUntilExit()
        let provider = IngestSourceProvider()
        provider.ffmpegPath = ff
        provider.propResolver = { _ in (mp4, .video) }
        let box = SampleBox()
        var registered: String?
        provider.onPhoneCreated = { registered = $0 }
        provider.phoneAudio = { key, l, _ in box.add(key, l) }
        _ = provider.source(for: .prop(id: "clip"))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let (key, n, rms) = box.snapshot()
        #expect(registered == "prop:clip" && key == "prop:clip", "key \(String(describing: registered)) \(String(describing: key))")
        #expect(n > 30_000, "samples \(n)")                 // ~real time: 48k/s, ffmpeg -re
        #expect(rms > 0.05, "rms \(rms)")                  // the sine is there (lavfi sine is 1/8 amplitude = rms ~0.088)
        provider.restartVideos([.prop(id: "clip")])          // must not deadlock, and keeps audio flowing
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(box.snapshot().1 > n)
        provider.stopAll()
    }
}

final class SampleBox: @unchecked Sendable {
    private let lock = NSLock(); private var key: String?; private var n = 0; private var sq = 0.0
    func add(_ k: String, _ l: [Float]) { lock.lock(); key = k; n += l.count; for v in l { sq += Double(v * v) }; lock.unlock() }
    func snapshot() -> (String?, Int, Double) { lock.lock(); defer { lock.unlock() }; return (key, n, n > 0 ? (sq / Double(n)).squareRoot() : 0) }
}

/// A video prop dropped in as an image layer is played as a video source (it showed black before).
@Suite struct VideoImageLayerTests {
    @Test func videoImageLayerBecomesSource() {
        let s = LayerScene(name: "x", layers: [
            Layer(name: "v", kind: .image(ImageSpec(propId: "vid")), transform: Transform(x: 0, y: 0, w: 1920, h: 1080)),
            Layer(name: "p", kind: .image(ImageSpec(propId: "pic")), transform: Transform(x: 0, y: 0, w: 10, h: 10)),
            .group("g", [Layer(name: "v2", kind: .image(ImageSpec(propId: "vid")), transform: Transform())])])
        let f = s.videoImagesAsSources { $0 == "vid" }
        #expect(f.sourceRefs.contains(.prop(id: "vid")))
        if case .source(.prop(let id), let fit) = f.layers[0].kind { #expect(id == "vid" && fit == .fit) } else { Issue.record("not a source") }
        if case .image = f.layers[1].kind {} else { Issue.record("picture changed") }
        if case .group(let kids) = f.layers[2].kind, case .source = kids[0].kind {} else { Issue.record("group child not fixed") }
        #expect(f.layers[0].transform == s.layers[0].transform)
    }
}
