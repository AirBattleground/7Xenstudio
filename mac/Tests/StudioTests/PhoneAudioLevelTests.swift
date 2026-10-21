import Testing
import Foundation
import CoreMedia
import CoreVideo
@testable import Studio

// Regression tests for "the iPad's game audio is missing / 15-25 dB too quiet in the recording".
// Root cause: the auto-duck trigger was the mic noise gate (-45 dB peak threshold), so ordinary room noise held the game audio
// 9 dB down for the whole show. The trigger is now a speech-level (RMS) detector; ducking is 6 dB by default.

private func rmsDb(_ x: ArraySlice<Float>) -> Double {
    let m = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))
    return 10 * log10(max(m, 1e-12))
}
private func runTool(_ path: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let o = Pipe(); p.standardOutput = o; p.standardError = o
    try? p.run(); let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}

/// Offline mixer render: a "game" tone on a program phone plus optional mic content, with the DEFAULT settings.
struct PhoneLevelScenario {
    var settings = AudioSettings()
    var micNoiseDb: Double? = nil          // RMS of broadband room noise on the mic; nil = no mic audio
    var micSpeech = false                  // 220 Hz loud "voice" at -14 dBFS RMS
    var seconds = 6

    func run() -> (outDb: Double, srcDb: Double, duckDb: Double) {
        let m = AudioMixer(jitterTargetMs: 0)
        m.addSource(id: "device:p")
        m.setProgramSources(["device:p"])
        var s = settings; s.phoneLatencyMs = 0; m.settings = s
        let n = 48_000 * seconds
        var out = [Float](), src = [Float](), duck = 0.0, blocks = 0
        var seed: UInt64 = 12345
        func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: seed >> 11) % 2_000_001) / 1_000_000 - 1 }
        let nAmp = micNoiseDb.map { Float(pow(10, $0 / 20) * 1.732) } ?? 0
        var pos = 0
        while pos < n {
            let k = 480
            let g = (0..<k).map { 0.2 * Float(sin(2 * Double.pi * 440 * Double(pos + $0) / 48_000)) }
            m.push(id: "device:p", left: g)
            if micSpeech { m.push(id: AudioMixer.micID, left: (0..<k).map { 0.28 * Float(sin(2 * Double.pi * 220 * Double(pos + $0) / 48_000)) }) }
            else if micNoiseDb != nil { m.push(id: AudioMixer.micID, left: (0..<k).map { _ in nAmp * rnd() }) }
            out += m.renderOffline(frames: k).l; src += g; pos += k
            duck += Double(m.meters().duckDb); blocks += 1
        }
        let a = 48_000 * 2
        return (rmsDb(out[a...]), rmsDb(src[a...]), duck / Double(blocks))
    }
}

@Suite struct PhoneAudioLevelTests {
    @Test func gameAudioIsUnityWithNoMicOrRoomNoise() {
        for noise in [nil, -70.0, -60.0, -50.0, -45.0, -40.0] as [Double?] {
            let r = PhoneLevelScenario(micNoiseDb: noise).run()
            #expect(abs(r.outDb - r.srcDb) < 0.3, "room noise \(noise.map { "\($0)" } ?? "none") dB: game audio \(r.outDb - r.srcDb) dB (duck \(r.duckDb))")
        }
    }
    @Test func gameAudioIsUnityWithMicMuted() {
        var s = AudioSettings(); s.mic.mute = true
        let r = PhoneLevelScenario(settings: s, micSpeech: true).run()
        #expect(abs(r.outDb - r.srcDb) < 0.3, "muted mic must never duck: \(r.outDb - r.srcDb)")
    }
    @Test func speechDucksBySixDbByDefault() {
        let r = PhoneLevelScenario(micSpeech: true).run()
        #expect(abs(r.duckDb + 6) < 0.6, "ducked by \(r.duckDb) dB")
    }
    @Test func legacyNineDbDuckSettingMigrates() throws {
        let s = try JSONDecoder().decode(AudioSettings.self, from: Data(#"{"duck":{"enabled":true,"amountDb":9}}"#.utf8))
        #expect(s.duck.amountDb == 6)
    }
    @Test func previewOnlyPhoneIsNotHeard() {
        let m = AudioMixer(jitterTargetMs: 0); m.addSource(id: "device:p")
        var s = AudioSettings(); s.phoneLatencyMs = 0; m.settings = s
        m.push(id: "device:p", left: [Float](repeating: 0.3, count: 48_000))
        #expect((m.renderOffline(frames: 48_000).l.map { abs($0) }.max() ?? 1) < 1e-4)
    }
    /// A take with a video fade: the audio glides over the same time, never drops out in the middle.
    @Test func takeCrossfadesGameAudioWithoutDropout() {
        let m = AudioMixer(jitterTargetMs: 0)
        m.addSource(id: "device:a"); m.addSource(id: "device:b")
        var s = AudioSettings(); s.phoneLatencyMs = 0; s.duck.enabled = false; m.settings = s
        m.setProgramSources(["device:a"])
        let n = 48_000
        m.push(id: "device:a", left: [Float](repeating: 0.4, count: n * 2)); m.push(id: "device:b", left: [Float](repeating: 0.4, count: n * 2))
        _ = m.renderOffline(frames: 4800)
        m.setProgramSources(["device:b"], fadeMs: 300)
        let o = m.renderOffline(frames: 24_000).l
        let sum = o[1000..<14_000]
        #expect(sum.min()! > 0.37 && sum.max()! < 0.43, "crossfade of equal signals must stay at unity: \(sum.min()!)...\(sum.max()!)")
        #expect(abs(o[23_000] - 0.4) < 0.01)
        // the fade is gradual, not a ~20 ms switch: a lone outgoing source (incoming has no audio yet) is at half level mid-transition
        let m2 = AudioMixer(jitterTargetMs: 0)
        m2.addSource(id: "device:a"); m2.addSource(id: "device:b"); m2.settings = s
        m2.setProgramSources(["device:a"])
        m2.push(id: "device:a", left: [Float](repeating: 0.4, count: n * 2))
        _ = m2.renderOffline(frames: 4800)
        m2.setProgramSources(["device:b"], fadeMs: 300)
        let o2 = m2.renderOffline(frames: 24_000).l
        #expect(abs(o2[7200] - 0.2) < 0.03, "mid-fade level \(o2[7200])")
        #expect(o2[20_000] < 0.001)
    }
}

// MARK: integration - real MediaMTX + PhoneAudioReader + engine + OutputPipeline recording

@Suite(.serialized) struct PhoneAudioRecordingIntegration {
    /// Synthetic phone (RTMP, 440 Hz AAC at 0.125 amplitude = -21.07 dBFS RMS) on Program, recorded 8 s; the MP4's audio must be at the
    /// source level (+-1.5 dB). Variants: mic muted, and mic live with a quiet room-noise floor (-52 dB RMS).
    @Test func recordedAudioMatchesPhoneLevel() async throws {
        guard let ff = FFmpegLocator.locate(), MediaMTXSupervisor.findBinary() != nil else { return }
        for (label, micMode) in [("mic muted", 0), ("mic live + room noise", 1)] {
            let ports = MediaMTXPorts(studio: 4431 + micMode, rtmp: 1971 + micMode, hls: 8924 + micMode, api: 9935 + micMode)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audio-rec-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let svc = try IngestService(dir: dir, ports: ports)
            svc.start(); defer { svc.stop() }
            let created = try svc.devices.create(name: "Fake iPad")
            let base = "http://127.0.0.1:\(ports.studio)"
            func post(_ path: String, _ body: [String: Any]) async throws -> (Int, [String: Any]) {
                var r = URLRequest(url: URL(string: base + path)!); r.httpMethod = "POST"
                r.setValue(created.key, forHTTPHeaderField: "X-Device-Key"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (d, resp) = try await URLSession.shared.data(for: r)
                return ((resp as! HTTPURLResponse).statusCode, (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:])
            }
            for _ in 0..<50 { if (try? await post("/api/device/hello", ["deviceModel": "iPad", "osVersion": "17.0", "appVersion": "1.0"]))?.0 == 200 { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let start = try await post("/api/device/stream/start", ["quality": "1080p", "fps": 30])
            let name = try #require(start.1["streamName"] as? String)
            let pub = Process(); pub.executableURL = URL(fileURLWithPath: ff)
            pub.arguments = ["-v", "error", "-re", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                             "-af", "pan=stereo|c0=c0|c1=c0",
                             "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency", "-g", "30", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-f", "flv",
                             "rtmp://127.0.0.1:\(ports.rtmp)/live/\(name)"]
            pub.standardOutput = Pipe(); pub.standardError = Pipe()
            try pub.run(); defer { pub.terminate() }

            let engine = StudioEngine(), out = OutputPipeline()
            var s = AudioSettings()                      // DEFAULT settings (duck on, gate on)
            s.mic.mute = micMode == 0
            engine.audio.settings = s
            let mx = engine.audio
            svc.sourceProvider.onPhoneCreated = { mx.addSource(id: $0, followsProgram: true, jitterMs: 150) }
            svc.sourceProvider.phoneAudio = { k, l, r in mx.push(id: k, left: l, right: r) }
            let rec = dir.appendingPathComponent("rec.mp4")
            var cfg = OutputConfig(ffmpegPath: ff); cfg.recordingURL = rec
            try out.start(cfg)
            #expect(engine.start(fps: 60, sink: out, provider: svc.sourceProvider))
            let scene = Scene(id: "p", name: "p", layout: .full, slots: [.device(id: created.device.id)])
            engine.setProgram(scene, fade: false)
            final class Flag: @unchecked Sendable { var stop = false }
            let flag = Flag()
            let micThread = Thread {
                var seed: UInt64 = 99; var next = MachTime.now
                let amp = Float(pow(10, -52.0 / 20) * 1.732)
                while !flag.stop {
                    mx.push(id: AudioMixer.micID, left: (0..<480).map { _ in seed = seed &* 6364136223846793005 &+ 1442695040888963407; return amp * (Float(Int64(bitPattern: seed >> 11) % 2_000_001) / 1_000_000 - 1) })
                    next += MachTime.ticks(seconds: 0.01); mach_wait_until(next)
                }
            }
            if micMode == 1 { micThread.start() }
            try await Task.sleep(nanoseconds: 11_000_000_000)
            let st = mx.inputStats(id: "device:\(created.device.id)")
            flag.stop = true
            engine.stop()
            await out.stop()
            let vol = runTool(ff, ["-hide_banner", "-ss", "4", "-i", rec.path, "-vn", "-af", "volumedetect", "-f", "null", "-"])
            func val(_ key: String) -> Double? {
                guard let r = vol.range(of: key + ": ") else { return nil }
                return Double(vol[r.upperBound...].prefix { !" \n".contains($0) })
            }
            let mean = try #require(val("mean_volume"), "no audio in recording (\(label)): \(vol.suffix(300))")
            print("PHONE-REC[\(label)] mean=\(mean) dB (source -21.07) underruns=\(st.underruns) dropped=\(st.droppedFrames) buffered=\(st.buffered) servo=\(st.servoPpm)ppm in=\(st.framesIn) active=\(st.active)")
            #expect(abs(mean + 21.07) < 1.5, "\(label): recorded game audio \(mean) dB vs source -21.07 dB")
        }
    }
}
