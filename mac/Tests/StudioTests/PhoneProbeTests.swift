import Testing
import Foundation
import CoreMedia
import CoreVideo
import QuartzCore
import Darwin
@testable import Studio

/// Probes for the phone video path. Manual (they need a publishing phone / local mediamtx):
///   STUDIO_LIVE_DEVICE=<id> swift test --filter RealPhoneProbe          (real phone via the running studio's mediamtx)
///   STUDIO_SYNTH_PROBE=1    swift test --filter SyntheticPhoneProbe     (480p/720p/1080p60 [+B-frames] synthetic publishers)
enum PhoneProbe {
    static func pct(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? 0 : a.sorted()[min(a.count - 1, Int(Double(a.count) * p))] }
    static func cpu() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6 }

    final class Acc: @unchecked Sendable { var frames = 0, distinct = 0, last: CVPixelBuffer?, lastNew = 0.0, firstAt: Double?; var gaps: [Double] = [] }

    /// Polls latestFrame() on the engine's realtime 60 Hz clock; returns a one-line report.
    static func cadence(_ src: PhoneSource, label: String, seconds: Double = 15, warmup: Double = 0) async throws -> String {
        let acc = Acc(), t0 = CACurrentMediaTime(), clock = FrameClock(fps: 60)
        let cpu0 = cpu()
        clock.start { _ in
            let now = CACurrentMediaTime()
            guard let f = src.latestFrame() else { return }
            acc.frames += 1
            if f !== acc.last {
                acc.distinct += 1; acc.last = f
                if acc.firstAt == nil { acc.firstAt = now - t0 } else { acc.gaps.append((now - acc.lastNew) * 1000) }
                acc.lastNew = now
            }
        }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        clock.stop()
        let cpuPct = (cpu() - cpu0) / seconds * 100
        let m = src.metrics, span = (CACurrentMediaTime() - t0) - (acc.firstAt ?? 0)
        return String(format: "PHONE-CADENCE[%@] firstFrame=%.2fs distinctFPS=%.1f gap p50=%.1f p95=%.1f p99=%.1f max=%.1f ms decodedFPS=%.1f latency=%.0fms decode avg=%.1f max=%.1f ms stalls=%d rebuilds=%d dropped=%d appCPU=%.0f%%",
                      label, acc.firstAt ?? -1, Double(acc.distinct) / max(0.1, span), pct(acc.gaps, 0.5), pct(acc.gaps, 0.95), pct(acc.gaps, 0.99), acc.gaps.max() ?? 0,
                      m.decodedFPS, m.latency * 1000, m.decodeMsAvg, m.decodeMsMax, m.stalls, m.rebuilds, m.droppedFrames, cpuPct)
    }

    /// Real StudioEngine + provider: counts how often consecutive program frames differ (phone content updating every output frame).
    static func engine(provider: IngestSourceProvider, device id: String, label: String, seconds: Double = 10) async throws -> String {
        final class Sink: VideoSink, @unchecked Sendable { func submit(video: CVPixelBuffer, pts: CMTime) {}; func submit(audio: CMSampleBuffer) {} }
        final class Box: @unchecked Sendable { let lock = NSLock(); var hashes: [UInt64] = [] }
        let engine = StudioEngine(), box = Box(), sink = Sink()
        engine.onProgramFrame = { pb in
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb)
            var h: UInt64 = 1469598103934665603
            for y in stride(from: 3, to: CVPixelBufferGetHeight(pb), by: 29) { for x in stride(from: 5, to: CVPixelBufferGetWidth(pb), by: 31) {
                h = (h ^ UInt64(base[y * bpr + x * 4 + 1])) &* 1099511628211 } }
            box.lock.withLock { box.hashes.append(h) }
        }
        #expect(engine.start(fps: 60, sink: sink, provider: provider))
        engine.setProgram(Scene(id: "p", name: "p", layout: .full, slots: [.device(id: id)]), fade: false)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        box.lock.withLock { box.hashes.removeAll() }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        let efps = engine.fps
        engine.stop()
        let h = box.lock.withLock { box.hashes }
        var changes = 0; for i in 1..<max(1, h.count) where h[i] != h[i - 1] { changes += 1 }
        return String(format: "PHONE-ENGINE[%@] outputFrames/s=%.1f (engine fps %.1f) phoneContentChanges/s=%.1f", label, Double(h.count) / seconds, efps, Double(changes) / seconds)
    }
}

@Suite(.serialized) struct RealPhoneProbe {
    @Test func realPhoneCadence() async throws {
        guard let id = ProcessInfo.processInfo.environment["STUDIO_LIVE_DEVICE"] else { return }
        let src = PhoneSource(deviceId: id)
        print(try await PhoneProbe.cadence(src, label: "real"))
        src.stop()
    }
    @Test func realPhoneThroughEngine() async throws {
        guard let id = ProcessInfo.processInfo.environment["STUDIO_LIVE_DEVICE"] else { return }
        let provider = IngestSourceProvider()
        _ = provider.phone(id)
        try await Task.sleep(nanoseconds: 4_000_000_000)
        print(try await PhoneProbe.engine(provider: provider, device: id, label: "real"))
        provider.stopAll()
    }
}

@Suite(.serialized) struct SyntheticPhoneProbe {
    @Test func syntheticResolutions() async throws {
        guard ProcessInfo.processInfo.environment["STUDIO_SYNTH_PROBE"] != nil,
              let ff = FFmpegLocator.locate(), MediaMTXSupervisor.findBinary() != nil else { return }
        let ports = MediaMTXPorts(studio: 4412, rtmp: 1952, hls: 8905, api: 9906)
        let svc = try IngestService(dir: FileManager.default.temporaryDirectory.appendingPathComponent("synth-\(UUID().uuidString)"), ports: ports)
        svc.start(); defer { svc.stop() }
        let created = try svc.devices.create(name: "Synth")
        let base = "http://127.0.0.1:\(ports.studio)"
        func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
            var r = URLRequest(url: URL(string: base + path)!); r.httpMethod = "POST"
            r.setValue(created.key, forHTTPHeaderField: "X-Device-Key"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (d, _) = try await URLSession.shared.data(for: r)
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        }
        var hello: [String: Any] = [:]
        for _ in 0..<50 { if let h = try? await post("/api/device/hello", ["deviceModel": "iPad", "osVersion": "17.0", "appVersion": "1.0"]), !h.isEmpty { hello = h; break }; try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(!hello.isEmpty)
        for _ in 0..<100 {   // wait for RTMP
            let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/nc"); t.arguments = ["-z", "127.0.0.1", "\(ports.rtmp)"]
            t.standardOutput = Pipe(); t.standardError = Pipe(); try? t.run(); t.waitUntilExit()
            if t.terminationStatus == 0 { break }; try await Task.sleep(nanoseconds: 100_000_000)
        }
        let start = try await post("/api/device/stream/start", ["quality": "1080p", "fps": 60])
        let name = try #require(start["streamName"] as? String)
        let url = "rtmp://127.0.0.1:\(ports.rtmp)/live/\(name)"
        let id = created.device.id
        try? url.write(toFile: "/tmp/synth.url", atomically: true, encoding: .utf8)
        let src = try #require(svc.sourceProvider.phone(id))

        // (w, h, kbps, bframes, label)
        let configs: [(Int, Int, Int, Int, String)] = [(854, 480, 2000, 0, "480p60"), (1280, 720, 6000, 0, "720p60"), (1920, 1080, 11000, 0, "1080p60"),
                                                       (1920, 1080, 11000, 2, "1080p60+B"), (854, 480, 2000, 0, "480p60 again")]
        var lines: [String] = []
        let only = ProcessInfo.processInfo.environment["STUDIO_SYNTH_ONLY"]
        for (w, h, kbps, bf, label) in configs where only == nil || label == only {
            let pub = Process(); pub.executableURL = URL(fileURLWithPath: ff)
            var a = ["-v", "error", "-re", "-f", "lavfi", "-i", "testsrc2=size=\(w)x\(h):rate=60", "-c:v", "libx264", "-preset", bf > 0 ? "veryfast" : "ultrafast",
                     "-profile:v", "high", "-pix_fmt", "yuv420p", "-b:v", "\(kbps)k", "-maxrate", "\(kbps)k", "-bufsize", "\(kbps)k", "-g", "120", "-keyint_min", "120", "-sc_threshold", "0"]
            a += bf > 0 ? ["-bf", "\(bf)"] : ["-bf", "0", "-tune", "zerolatency"]
            a += ["-f", "flv", url]
            pub.arguments = a; pub.standardOutput = Pipe(); pub.standardError = ProcessInfo.processInfo.environment["STUDIO_DEBUG_PHONE"] != nil ? FileHandle.standardError : Pipe()
            try pub.run()
            if let hold = ProcessInfo.processInfo.environment["STUDIO_SYNTH_HOLD"], let secs = Double(hold) { try await Task.sleep(nanoseconds: UInt64(secs * 1e9)) }
            // wait for frames of the new geometry (reconnect + SPS change + keyframe)
            let deadline = Date().addingTimeInterval(30)
            var first: CVPixelBuffer?
            while Date() < deadline {
                if let f = src.latestFrame(), CVPixelBufferGetWidth(f) == w, src.metrics.decodedFPS > 40 { first = f; break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            lines.append("PHONE-SWITCH[\(label)] first \(w)-wide frame: \(first == nil ? "NONE" : "ok")")
            #expect(first != nil, "no \(label) frame")
            try await Task.sleep(nanoseconds: 2_000_000_000)
            lines.append(try await PhoneProbe.cadence(src, label: label, seconds: 10))
            lines.append(try await PhoneProbe.engine(provider: svc.sourceProvider, device: id, label: label, seconds: 6))
            pub.terminate(); pub.waitUntilExit()
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        lines.forEach { print($0) }
        svc.sourceProvider.stopAll()
    }
}
