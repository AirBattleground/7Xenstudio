import Testing
import SwiftUI
import AppKit
import AVKit
import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Studio

func sh(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let o = Pipe(); p.standardOutput = o; p.standardError = o
    try? p.run(); let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}
private func tmpDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("studio-e2e-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
}
private func writePNG(_ url: URL, r: CGFloat, g: CGFloat, b: CGFloat) {
    let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
}
private func waitFor(_ secs: Double, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
    return cond()
}

@Suite(.serialized) struct PropSourceTests {
    @Test func imagePropAndVideoPropProduceFrames() async throws {
        let dir = tmpDir()
        let store = try StudioStore(dir: dir)
        let png = dir.appendingPathComponent("red.png"); writePNG(png, r: 1, g: 0, b: 0)
        let img = try store.addProp(file: png)
        let provider = IngestSourceProvider()
        provider.propResolver = { id in store.propURL(id).flatMap { u in store.props.first { $0.id == id }.map { (u, $0.kind) } } }
        let s = try #require(provider.source(for: .prop(id: img.id)))
        let pb = try #require(s.latestFrame())
        #expect(CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let px = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        #expect(px[2] > 240 && px[1] < 60 && px[0] < 30, "bgra \(px[0]) \(px[1]) \(px[2]) \(px[3]) \(CVPixelBufferGetWidth(pb))")   // BGRA red
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        #expect(provider.source(for: .prop(id: "nope")) == nil)

        if let ff = FFmpegLocator.locate() {
            let mp4 = dir.appendingPathComponent("clip.mp4")
            let (st, out) = sh(ff, ["-v", "error", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30:duration=1", "-pix_fmt", "yuv420p", "-c:v", "libx264", "-y", mp4.path])
            #expect(st == 0, "\(out)")
            let vp = try store.addProp(file: mp4)
            let v = try #require(provider.source(for: .prop(id: vp.id)) as? VideoFileSource)
            var got: CVPixelBuffer?
            let ok = await waitFor(6) { got = v.latestFrame(); return got != nil }
            #expect(ok, "no video frame")
            // loops: still producing new frames after > clip length
            try await Task.sleep(nanoseconds: 2_500_000_000)
            for _ in 0..<30 { _ = v.latestFrame(); try await Task.sleep(nanoseconds: 33_000_000) }
            #expect(v.decodedFPS > 5, "fps \(v.decodedFPS)")
        }
        provider.stopAll()
    }
}

@Suite(.serialized) struct PhoneIngestE2E {
    @Test func fakePhonePairsPublishesAndEngineShowsIt() async throws {
        guard let ff = FFmpegLocator.locate(), MediaMTXSupervisor.findBinary() != nil else { return }
        let ports = MediaMTXPorts(studio: 4411, rtmp: 1951, hls: 8904, api: 9905)
        let svc = try IngestService(dir: tmpDir(), ports: ports)
        svc.start()
        defer { svc.stop() }
        #expect(svc.lastError == nil)
        let created = try svc.devices.create(name: "Fake phone")
        let base = "http://127.0.0.1:\(ports.studio)"
        func post(_ path: String, _ body: [String: Any]) async throws -> (Int, [String: Any]) {
            var r = URLRequest(url: URL(string: base + path)!); r.httpMethod = "POST"
            r.setValue(created.key, forHTTPHeaderField: "X-Device-Key"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (d, resp) = try await URLSession.shared.data(for: r)
            return ((resp as! HTTPURLResponse).statusCode, (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:])
        }
        // the server may need a moment to listen
        var hello: (Int, [String: Any]) = (0, [:])
        for _ in 0..<30 { if let h = try? await post("/api/device/hello", ["deviceModel": "iPhone15,2", "osVersion": "17.0", "appVersion": "1.0"]) { hello = h; break }; try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(hello.0 == 200, "hello \(hello)")
        let rtmpUp = await waitFor(10) {
            let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/nc"); t.arguments = ["-z", "127.0.0.1", "\(ports.rtmp)"]
            t.standardOutput = Pipe(); t.standardError = Pipe(); try? t.run(); t.waitUntilExit(); return t.terminationStatus == 0
        }
        #expect(rtmpUp, "mediamtx RTMP never listened")
        let start = try await post("/api/device/stream/start", ["quality": "1080p", "fps": 30])
        #expect(start.0 == 200)
        let name = try #require(start.1["streamName"] as? String)
        let url = "rtmp://127.0.0.1:\(ports.rtmp)/live/\(name)"

        // bad token must be refused
        let bad = Process(); bad.executableURL = URL(fileURLWithPath: ff)
        bad.arguments = ["-v", "error", "-re", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30:duration=2", "-c:v", "libx264", "-f", "flv", "rtmp://127.0.0.1:\(ports.rtmp)/live/dev_\(created.device.id)?token=bogus"]
        bad.standardOutput = Pipe(); bad.standardError = Pipe()
        try bad.run(); bad.waitUntilExit()
        #expect(bad.terminationStatus != 0)

        let pub = Process(); pub.executableURL = URL(fileURLWithPath: ff)
        pub.arguments = ["-v", "error", "-re", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                         "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency", "-g", "30", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k", "-f", "flv", url]
        let perr = Pipe(); pub.standardOutput = Pipe(); pub.standardError = perr
        try pub.run()
        defer { pub.terminate() }

        let phone = try #require(svc.sourceProvider.phone(created.device.id))
        let flowing = await waitFor(25) { _ = phone.latestFrame(); return phone.metrics.decodedFPS > 0 }
        let errText = pub.isRunning ? "" : String(decoding: perr.fileHandleForReading.availableData, as: UTF8.self)
        #expect(flowing, "no frames from phone; publisher: \(errText)")
        let statuses = await svc.devices.statuses()
        #expect(statuses.first?.videoReady == true)
        print("PHONE decodedFPS=\(phone.metrics.decodedFPS) latency=\(phone.metrics.latency)")

        // engine shows it
        let engine = StudioEngine()
        final class Sink: VideoSink, @unchecked Sendable { func submit(video: CVPixelBuffer, pts: CMTime) {}; func submit(audio: CMSampleBuffer) {} }
        let sink = Sink()
        final class Box: @unchecked Sendable { var pb: CVPixelBuffer? }
        let box = Box()
        engine.onProgramPreview = { box.pb = $0 }
        #expect(engine.start(fps: 60, sink: sink, provider: svc.sourceProvider))
        engine.setProgram(Scene(id: "p", name: "p", layout: .full, slots: [.device(id: created.device.id)]), fade: false)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let pb = try #require(box.pb)
        // testsrc2 is colourful: the preview must not be flat
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let base0 = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb)
        var distinct = Set<UInt32>()
        for y in stride(from: 10, to: CVPixelBufferGetHeight(pb) - 10, by: 12) { for x in stride(from: 10, to: CVPixelBufferGetWidth(pb) - 10, by: 12) {
            let p = base0 + y * bpr + x * 4; distinct.insert(UInt32(p[0] >> 4) | UInt32(p[1] >> 4) << 8 | UInt32(p[2] >> 4) << 16) } }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        engine.stop()
        #expect(distinct.count > 6, "program preview looks flat (\(distinct.count) colours)")
    }
}

@Suite(.serialized) struct GoLiveE2E {
    @Test func engineToOutputRecords1080p60() async throws {
        guard let ff = FFmpegLocator.locate(), let probe = FFmpegLocator.ffprobe(besides: ff) else { return }
        let dir = tmpDir()
        let png = dir.appendingPathComponent("c.png"); writePNG(png, r: 0.1, g: 0.5, b: 0.9)
        let store = try StudioStore(dir: dir)
        let prop = try store.addProp(file: png)
        let provider = IngestSourceProvider()
        provider.propResolver = { id in store.propURL(id).map { ($0, StoredProp.Kind.image) } }
        let engine = StudioEngine(), out = OutputPipeline()
        let rec = dir.appendingPathComponent("rec.mp4")
        var cfg = OutputConfig(ffmpegPath: ff); cfg.recordingURL = rec
        try out.start(cfg)
        #expect(engine.start(fps: 60, sink: out, provider: provider))
        engine.setProgram(Scene(id: "p", name: "p", layout: .full, slots: [.prop(id: prop.id)]), fade: false)
        engine.setOverlays({ var o = Overlays(); o.liveBug = true; return o }())
        engine.setLiveClock(since: Date())
        try await Task.sleep(nanoseconds: 5_000_000_000)
        let stats = out.stats, efps = engine.fps
        engine.stop()
        await out.stop()
        let (st, j) = sh(probe, ["-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries", "stream=codec_name,width,height,avg_frame_rate,nb_read_frames,duration", "-of", "default=nw=0", rec.path])
        print("GOLIVE ffprobe:\n\(j)\nengine fps=\(efps) kbps=\(stats.kbps) dropped=\(stats.droppedFrames) err=\(stats.error ?? "-")")
        #expect(st == 0)
        #expect(j.contains("codec_name=h264") && j.contains("width=1920") && j.contains("height=1080"))
        let fr = j.split(separator: "\n").first { $0.hasPrefix("avg_frame_rate=") }.map { String($0.dropFirst(15)) } ?? ""
        let p = fr.split(separator: "/").compactMap(Double.init)
        #expect(p.count == 2 && p[1] > 0 && abs(p[0] / p[1] - 60) < 4, "avg_frame_rate \(fr)")
        let frames = Int(j.split(separator: "\n").first { $0.hasPrefix("nb_read_frames=") }.map { String($0.dropFirst(15)) } ?? "") ?? 0
        #expect(frames > 270 && frames < 330, "frames \(frames)")
        RealServices.finalizeRecording(rec, ffmpeg: ff)
        // duration via AVURLAsset (what the Recordings tab uses)
        let d = CMTimeGetSeconds(try await AVURLAsset(url: rec).load(.duration))
        print("AVURLAsset duration \(d)")
        #expect(d > 3.5 && d < 6.5)
    }
}
import AVFoundation

@Suite(.serialized) @MainActor struct PlayerViewTests {
    @Test func recordingPlayerBuildsAndTearsDown() async throws {
        guard let ff = FFmpegLocator.locate() else { return }
        let mp4 = tmpDir().appendingPathComponent("p.mp4")
        _ = sh(ff, ["-v", "error", "-f", "lavfi", "-i", "testsrc=size=320x180:rate=30:duration=1", "-pix_fmt", "yuv420p", "-c:v", "libx264", "-y", mp4.path])
        _ = NSApplication.shared
        let host = NSHostingView(rootView: RecordingPlayer(url: mp4).frame(width: 640, height: 360))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = host
        win.orderBack(nil)
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(host.subviews.contains { $0 is AVPlayerView } || host.fittingSize.width > 0)
        win.contentView = nil   // dismantle
        try await Task.sleep(nanoseconds: 200_000_000)
    }
}
