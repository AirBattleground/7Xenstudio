// Hidden headless stress mode (not reachable from the UI): STUDIO_STRESS=1,2,4 .build/release/Studio
// Publishes N synthetic 1080p60 H.264 RTMP "phones" (ffmpeg, -c copy from a pre-encoded libx264 ultrafast 8 Mbps clip so the
// publishers do not steal the CPU being measured) into a real mediamtx using properly signed device tokens, then runs the real
// StudioEngine + OutputPipeline (1080p60 recording + one RTMP destination) and reports engine / output / process numbers.
// Env: STUDIO_STRESS_SECS (default 30), STUDIO_STRESS_SAMPLE=<dir> (run `sample` on the process mid-run), STUDIO_STRESS_HEVC=1.
import Foundation
import AppKit
import CoreVideo
import CoreMedia
import Darwin
import QuartzCore

enum Stress {
    static var requested: Bool { ProcessInfo.processInfo.environment["STUDIO_STRESS"] != nil }

    @MainActor static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let counts = (ProcessInfo.processInfo.environment["STUDIO_STRESS"] ?? "1").split(separator: ",").compactMap { Int($0) }
        let runner = StressRunner()
        Task { @MainActor in
            await runner.run(counts: counts)
            exit(0)
        }
        app.run()
    }
}

private func shell(_ path: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let o = Pipe(); p.standardOutput = o; p.standardError = o
    try? p.run(); let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}

final class FrameBox2: @unchecked Sendable {
    private let lock = NSLock(); private var pb: CVPixelBuffer?; private var n: UInt64 = 0
    func set(_ p: CVPixelBuffer) { lock.lock(); pb = p; n &+= 1; lock.unlock() }
    var serial: UInt64 { lock.lock(); defer { lock.unlock() }; return n }
    func get() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return pb }
}

final class Gaps: @unchecked Sendable {
    let lock = NSLock(); var stamps: [Double] = []
    func add(_ t: Double) { lock.lock(); stamps.append(t); lock.unlock() }
    func reset() { lock.lock(); stamps.removeAll(keepingCapacity: true); lock.unlock() }
    func summary() -> (fps: Double, p50: Double, p99: Double, max: Double, over25: Int) {
        lock.lock(); let s = stamps; lock.unlock()
        guard s.count > 2 else { return (0, 0, 0, 0, 0) }
        let g = zip(s.dropFirst(), s).map { ($0 - $1) * 1000 }.sorted()
        return (Double(s.count - 1) / (s.last! - s.first!), g[g.count / 2], g[min(g.count - 1, Int(Double(g.count) * 0.99))], g.last!, g.filter { $0 > 25 }.count)
    }
}

struct ThreadCPU { var name: String; var tid: UInt64; var ns: UInt64; var prio: Int32 }

func snapshotThreads() -> [UInt64: ThreadCPU] {
    var list: thread_act_array_t?; var n: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &n) == KERN_SUCCESS, let list else { return [:] }
    var out: [UInt64: ThreadCPU] = [:]
    for i in 0..<Int(n) {
        let t = list[i]
        var idi = thread_identifier_info(); var c1 = mach_msg_type_number_t(MemoryLayout<thread_identifier_info>.size / MemoryLayout<integer_t>.size)
        withUnsafeMutablePointer(to: &idi) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c1)) { _ = thread_info(t, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &c1) } }
        var ex = thread_extended_info(); var c2 = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<integer_t>.size)
        withUnsafeMutablePointer(to: &ex) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c2)) { _ = thread_info(t, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &c2) } }
        let name = withUnsafePointer(to: &ex.pth_name) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) } }
        out[idi.thread_id] = ThreadCPU(name: name, tid: idi.thread_id, ns: ex.pth_user_time + ex.pth_system_time, prio: ex.pth_curpri)
        mach_port_deallocate(mach_task_self_, t)
    }
    vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), vm_size_t(Int(n) * MemoryLayout<thread_t>.size))
    return out
}

func rusageSeconds() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

func physFootprintMB() -> Double {
    var info = task_vm_info_data_t(); var c = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &c) } }
    return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

@MainActor
final class StressRunner {
    let env = ProcessInfo.processInfo.environment
    var tmp = FileManager.default.temporaryDirectory.appendingPathComponent("studio-stress-\(UUID().uuidString)")
    var publishers: [Process] = []
    var mainTid: UInt64 = { var t: UInt64 = 0; pthread_threadid_np(nil, &t); return t }()

    func say(_ s: String) { print(s); fflush(stdout) }

    func run(counts: [Int]) async {
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        guard let ff = FFmpegLocator.locate(), MediaMTXSupervisor.findBinary() != nil else { say("STRESS: ffmpeg/mediamtx missing"); return }
        let maxN = counts.max() ?? 1
        // distinct ports from the app (4400/1940/8893/9994) and the tests (4411/1951/8904/9905)
        let ports = MediaMTXPorts(studio: 4521, rtmp: 1961, hls: 8914, api: 9925)
        guard let svc = try? IngestService(dir: tmp, ports: ports) else { say("STRESS: store failed"); return }
        svc.start()
        defer { svc.stop(); publishers.forEach { $0.terminate() } }

        // 1080p60 8 Mbps libx264 ultrafast clip (testsrc2), keyframe every second, 10 s loop
        let clip = tmp.appendingPathComponent("feed.mp4")
        _ = shell(ff, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=60:duration=10", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=10",
                       "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-b:v", "8M", "-maxrate", "8M", "-bufsize", "4M", "-g", "60", "-bf", "0", "-pix_fmt", "yuv420p",
                       "-c:a", "aac", "-b:a", "96k", clip.path])

        // pair maxN phones + one sink device that receives the engine's RTMP output
        var devs: [(id: String, name: String)] = []
        var sinkName = ""
        for i in 0...maxN {
            guard let c = try? svc.devices.create(name: i == maxN ? "sink" : "Phone \(i + 1)") else { return }
            let base = "http://127.0.0.1:\(ports.studio)"
            func post(_ path: String, _ body: [String: Any]) async -> [String: Any] {
                var r = URLRequest(url: URL(string: base + path)!); r.httpMethod = "POST"
                r.setValue(c.key, forHTTPHeaderField: "X-Device-Key"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try? JSONSerialization.data(withJSONObject: body)
                guard let (d, _) = try? await URLSession.shared.data(for: r) else { return [:] }
                return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
            }
            var ok = false
            for _ in 0..<50 { let h = await post("/api/device/hello", ["deviceModel": "iPhone15,2", "osVersion": "17.0", "appVersion": "1.0"]); if !h.isEmpty { ok = true; break }; try? await Task.sleep(nanoseconds: 100_000_000) }
            if !ok { say("STRESS: studio HTTP not up"); return }
            let st = await post("/api/device/stream/start", ["quality": "1080p", "fps": 60])
            guard let name = st["streamName"] as? String else { say("STRESS: no streamName \(st)"); return }
            if i == maxN { sinkName = name } else { devs.append((c.device.id, name)) }
        }

        // monitor window: the real MonitorNSView (display link -> IOSurface layer) so displayed cadence is measured
        let box = FrameBox2(), gaps = Gaps()
        let mon = MonitorNSView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
        mon.fps = 60
        mon.provider = { box.get().map { .pixels($0) } }
        mon.serial = { box.serial }
        mon.onShow = { gaps.add($0) }
        let win = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 480, height: 270), styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "stress"; win.contentView = mon; win.orderFrontRegardless()

        var table: [String] = []
        for n in counts {
            table.append(await runOne(n: n, ff: ff, svc: svc, ports: ports, clip: clip, devs: devs, sinkName: sinkName, box: box, gaps: gaps))
        }
        say("\n===== STRESS SUMMARY =====")
        say("N | fps | missed | held | frameP50 | frameP99(worst s) | gpuAvg | gpuP99 | outDropped | encLat | encFPS | kbps | CPU%(app) | CPU%(children) | main% | RSS MB | thermal | monitor fps/p99gap/max/over25 | phones fps")
        table.forEach { say($0) }
        win.close()
    }

    func runOne(n: Int, ff: String, svc: IngestService, ports: MediaMTXPorts, clip: URL, devs: [(id: String, name: String)], sinkName: String,
                box: FrameBox2, gaps: Gaps) async -> String {
        say("\n--- N=\(n) phones ---")
        let mixer = AudioMixerWiring()
        let engine = StudioEngine(), out = OutputPipeline()
        svc.sourceProvider.onPhoneCreated = { key in engine.audio.addSource(id: key, followsProgram: true, jitterMs: 150) }
        svc.sourceProvider.phoneAudio = { key, l, r in engine.audio.push(id: key, left: l, right: r) }
        _ = mixer
        engine.onProgramFrame = { box.set($0) }
        if env["STUDIO_STRESS_NOPREVIEW"] == nil { engine.onPreviewPreview = { _ in } }
        out.onLog = { [self] s in if env["STUDIO_STRESS_LOG"] != nil { print("LOG", s) } }
        var cfg = OutputConfig(ffmpegPath: ff)
        cfg.recordingURL = tmp.appendingPathComponent("rec-\(n).mp4")
        cfg.recordHEVC = env["STUDIO_STRESS_HEVC"] != nil
        cfg.destinations = [Destination(id: "sink", name: "sink", kind: .custom, url: "rtmp://127.0.0.1:\(ports.rtmp)/live", key: sinkName)]
        do { try out.start(cfg) } catch { say("STRESS: output start failed \(error)"); return "N=\(n) FAILED" }
        guard engine.start(fps: 60, sink: out, provider: svc.sourceProvider) else { say("STRESS: engine failed"); return "N=\(n) FAILED" }
        // synthetic commentary mic: 440 Hz + noise, 10 ms blocks on a utility thread
        let micStop = ManagedFlag()
        let micThread = Thread {
            var ph = 0.0; let step = 2 * Double.pi * 220 / 48000
            var next = MachTime.now
            while !micStop.value {
                let l = (0..<480).map { _ -> Float in ph += step; return Float(sin(ph) * 0.2 + Double.random(in: -0.02...0.02)) }
                engine.audio.push(id: AudioMixer.micID, left: l, right: l)
                next += MachTime.ticks(seconds: 0.01); mach_wait_until(next)
            }
        }
        micThread.name = "stress.mic"; micThread.start()

        let ids = devs.prefix(n).map(\.id)
        func dev(_ i: Int) -> SourceRef? { i < ids.count ? .device(id: ids[i]) : nil }
        let progScene: Scene, prevScene: Scene, altScene: Scene
        switch n {
        case 1: progScene = Scene(id: "p", name: "p", layout: .full, slots: [dev(0)]); prevScene = Scene(id: "v", name: "v", layout: .full, slots: [dev(0)])
                altScene = Scene(id: "a", name: "a", layout: .pip, slots: [dev(0), dev(0)])
        case 2: progScene = Scene(id: "p", name: "p", layout: .side, slots: [dev(0), dev(1)]); prevScene = Scene(id: "v", name: "v", layout: .pip, slots: [dev(1), dev(0)])
                altScene = Scene(id: "a", name: "a", layout: .pip, slots: [dev(0), dev(1)])
        case 3: progScene = Scene(id: "p", name: "p", layout: .trio, slots: [dev(0), dev(1), dev(2)]); prevScene = Scene(id: "v", name: "v", layout: .side, slots: [dev(1), dev(2)])
                altScene = Scene(id: "a", name: "a", layout: .trio, slots: [dev(2), dev(0), dev(1)])
        default:
            // >4 phones: scenes only have 3 slots, so the extra phones are listed past the layout's slots: they are decoded AND
            // converted by the compositor every frame (that is the per-source cost) but not drawn.
            let extra = (3..<n).map { dev($0) }
            progScene = Scene(id: "p", name: "p", layout: .trio, slots: [dev(0), dev(1), dev(2)] + extra.prefix(n > 4 ? 0 : 0))
            prevScene = Scene(id: "v", name: "v", layout: .side, slots: [dev(2), dev(3)] + extra.dropFirst())
            altScene = Scene(id: "a", name: "a", layout: .trio, slots: [dev(2), dev(0), dev(1)])
        }
        engine.setProgram(progScene, fade: false); engine.setPreview(prevScene)
        let fadeOn = env["STUDIO_STRESS_NOFADE"] == nil
        engine.transitionMs = 300
        engine.setOverlays({ var o = Overlays(); o.liveBug = true; o.ticker = true; o.tickerText = "7XEN STUDIO STRESS TEST  -  1080p60 multi phone"; return o }())
        engine.setLiveClock(since: Date())

        // publishers (start after the pipeline is up, as a real show would)
        var pubs: [Process] = []
        for i in 0..<n {
            let p = Process(); p.executableURL = URL(fileURLWithPath: ff)
            p.arguments = ["-v", "error", "-re", "-stream_loop", "-1", "-i", clip.path, "-c", "copy", "-f", "flv", "rtmp://127.0.0.1:\(ports.rtmp)/live/\(devs[i].name)"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); pubs.append(p)
        }
        publishers += pubs
        // wait until every phone delivers frames
        let sources = ids.compactMap { svc.sourceProvider.phone($0) }
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 40 {
            for s in sources { _ = s.latestFrame() }
            if sources.count == n && sources.allSatisfy({ $0.metrics.decodedFPS > 20 }) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        say("phones flowing after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s: " + sources.map { String(format: "%.0f", $0.metrics.decodedFPS) }.joined(separator: "/"))
        try? await Task.sleep(nanoseconds: 6_000_000_000)   // settle: encoder warm, GOP boundaries, jitter buffers primed

        // ---- measurement window ----
        let secs = Double(env["STUDIO_STRESS_SECS"] ?? "30") ?? 30
        let th0 = snapshotThreads(), wall0 = CACurrentMediaTime(), ru0 = rusageSeconds()
        let e0 = engine.stats, o0 = out.stats
        gaps.reset()
        let thermal0 = ProcessInfo.processInfo.thermalState
        var worstFrameP99 = 0.0, worstGpuP99 = 0.0, p50s: [Double] = [], fpsMin = 999.0
        var sampleProc: Process?
        let end = CACurrentMediaTime() + secs
        var sec = 0
        var onAlt = false, lastFade = CACurrentMediaTime()
        while CACurrentMediaTime() < end {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if fadeOn, CACurrentMediaTime() - lastFade >= 2.5 { onAlt.toggle(); engine.setProgram(onAlt ? altScene : progScene, fade: true); lastFade = CACurrentMediaTime() }
            if CACurrentMediaTime() - wall0 < Double(sec + 1) { continue }
            sec += 1
            let e = engine.stats
            worstFrameP99 = max(worstFrameP99, e.frameP99Ms); worstGpuP99 = max(worstGpuP99, e.gpuP99Ms); p50s.append(e.frameP50Ms)
            fpsMin = min(fpsMin, e.fps)
            if sec == Int(secs / 2), let dir = env["STUDIO_STRESS_SAMPLE"] {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let sp = Process(); sp.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                sp.arguments = ["\(getpid())", "5", "-file", "\(dir)/sample-n\(n).txt"]; sp.standardOutput = FileHandle.nullDevice; sp.standardError = FileHandle.nullDevice
                try? sp.run(); sampleProc = sp
            }
        }
        let wall = CACurrentMediaTime() - wall0
        let th1 = snapshotThreads(), ruPct = (rusageSeconds() - ru0) / wall * 100
        let e1 = engine.stats, o1 = out.stats, thermal1 = ProcessInfo.processInfo.thermalState
        let mg = gaps.summary()
        let rss = physFootprintMB()
        // per-thread CPU
        var rows: [(String, Double, Int32)] = []
        var total = 0.0, mainPct = 0.0
        for (tid, b) in th1 {
            let a = th0[tid]?.ns ?? 0
            let pct = Double(b.ns &- a) / 1e9 / wall * 100
            total += pct
            if tid == mainTid { mainPct = pct }
            rows.append((b.name.isEmpty ? "thread-\(tid)" : b.name, pct, b.prio))
        }
        rows.sort { $0.1 > $1.1 }
        say("threads (CPU% of one core, prio):")
        for r in rows.prefix(14) where r.1 >= 0.5 { say(String(format: "   %6.1f%%  p%-3d %@%@", r.1, r.2, r.0, r.0 == "" ? "" : (r.0.hasPrefix("thread-") && Int(r.0.dropFirst(7)) == Int(mainTid) ? " (main)" : ""))) }
        // children (ffmpeg readers, output ffmpeg, mediamtx, publishers)
        let kids = childCPU()
        say("children CPU% (lifetime avg): " + kids.map { "\($0.key)=\(String(format: "%.0f", $0.value))" }.sorted().joined(separator: " "))
        let childTotal = kids.filter { $0.key != "publisher" }.values.reduce(0, +)
        say(String(format: "phones decodedFPS: %@", sources.map { String(format: "%.0f", $0.metrics.decodedFPS) }.joined(separator: "/")))

        let missed = e1.missedDeadlines - e0.missedDeadlines, held = e1.heldFrames - e0.heldFrames, dropped = o1.droppedFrames - o0.droppedFrames
        let frames = e1.frames - e0.frames
        say(String(format: "engine: frames=%d (%.1f/s) fpsMin=%.1f missed=%d held=%d | frame p50~%.2f p99worst=%.2f ms | gpu avg=%.2f p99worst=%.2f ms | encode(cpu) p99=%.2f ms",
                   frames, Double(frames) / wall, fpsMin, missed, held, p50s.sorted()[p50s.count / 2], worstFrameP99, e1.gpuAvgMs, worstGpuP99, e1.encodeP99Ms))
        say(String(format: "output: dropped=%d encLatency=%.1f ms encFPS=%.1f kbps=%.0f restarts=%d err=%@ destErrors=%@", dropped, o1.encodeLatencyMs, o1.encodeFPS, o1.kbps, o1.restarts, o1.error ?? "-", "\(o1.destinationErrors)"))
        say(String(format: "rusage CPU=%.0f%% of one core | thread-sum=%.0f%% | app CPU=%.0f%% (main thread %.1f%%) footprint=%.0f MB thermal %d->%d | program monitor shown %.1f/s gap p50=%.1f p99=%.1f max=%.1f ms >25ms=%d",
                   ruPct, total, total, mainPct, rss, thermal0.rawValue, thermal1.rawValue, mg.fps, mg.p50, mg.p99, mg.max, mg.over25))
        sampleProc?.waitUntilExit()

        let phoneFPS = sources.map { String(format: "%.0f", $0.metrics.decodedFPS) }.joined(separator: "/")
        // teardown
        micStop.value = true
        pubs.forEach { $0.terminate() }
        engine.stop()
        await out.stop()
        svc.sourceProvider.stopAll()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return String(format: "N=%d | %.1f | %d | %d | %.2f | %.2f | %.2f | %.2f | %d | %.1f | %.1f | %.0f | %.0f | %.0f | %.1f | %.0f | %d | %.1f/%.1f/%.1f/%d | %@",
                      n, Double(frames) / wall, missed, held, p50s.sorted()[p50s.count / 2], worstFrameP99, e1.gpuAvgMs, worstGpuP99, dropped, o1.encodeLatencyMs, o1.encodeFPS, o1.kbps,
                      total, childTotal, mainPct, rss, thermal1.rawValue, mg.fps, mg.p99, mg.max, mg.over25, phoneFPS)
    }

    /// CPU% (ps lifetime average) of direct children, grouped by role.
    func childCPU() -> [String: Double] {
        let txt = shell("/bin/ps", ["-A", "-o", "ppid=,pcpu=,args="])
        let me = getpid()
        var out: [String: Double] = [:]
        for line in txt.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, Int32(f[0]) == me, let cpu = Double(f[1]) else { continue }
            let a = String(f[2])
            let role: String
            if a.contains("mediamtx") { role = "mediamtx" }
            else if a.contains("-stream_loop") { role = "publisher" }
            else if a.contains("f32le") { role = "audioReader" }
            else if a.contains("h264_mp4toannexb") { role = "videoReader" }
            else if a.contains("mpegts") && a.contains("pipe:0") { role = "outputFFmpeg" }
            else if a.contains("sample") { continue }
            else { role = "other" }
            out[role, default: 0] += cpu
        }
        return out
    }
}

private final class AudioMixerWiring {}

// MARK: - full-app mode: STUDIO_STRESS_UI=<n phones> runs the real SwiftUI app (RealServices, Studio page, monitors, 0.5 s AppModel refresh)
// on a temp store and alternate ports, drives it like an operator (pair phones, scenes, Go Live with recording + one RTMP output)
// and reports the same numbers plus main-thread CPU and the real program monitor cadence.
extension Stress {
    static var uiRequested: Bool { ProcessInfo.processInfo.environment["STUDIO_STRESS_UI"] != nil }
    static let uiDir = FileManager.default.temporaryDirectory.appendingPathComponent("studio-stressui-\(UUID().uuidString)")
    static let uiPorts = MediaMTXPorts(studio: 4531, rtmp: 1971, hls: 8924, api: 9935)
    static func uiIngest() throws -> IngestService {
        try FileManager.default.createDirectory(at: uiDir, withIntermediateDirectories: true)
        let n = Int(ProcessInfo.processInfo.environment["STUDIO_STRESS_RECORDINGS"] ?? "0") ?? 0
        if n > 0 {   // a big library makes AppModel.refresh()'s recordings() scan realistic
            let rd = uiDir.appendingPathComponent("recordings"); try FileManager.default.createDirectory(at: rd, withIntermediateDirectories: true)
            for i in 0..<n { FileManager.default.createFile(atPath: rd.appendingPathComponent("old-\(i).mp4").path, contents: Data(count: 1024)) }
        }
        return try IngestService(dir: uiDir, ports: uiPorts)
    }

    @MainActor static func startUIScenario(_ delegate: AppDelegate) {
        Task { @MainActor in
            for _ in 0..<100 { if delegate.model != nil { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
            guard let model = delegate.model, let svc = model.services as? RealServices else { print("STRESSUI: no real services"); exit(1) }
            await UIScenario(model: model, svc: svc).run()
            exit(0)
        }
    }
}

@MainActor
final class UIScenario {
    let model: AppModel, svc: RealServices
    let env = ProcessInfo.processInfo.environment
    init(model: AppModel, svc: RealServices) { self.model = model; self.svc = svc }
    func say(_ s: String) { print(s); fflush(stdout) }

    func run() async {
        let n = Int(env["STUDIO_STRESS_UI"] ?? "2") ?? 2
        guard let ff = FFmpegLocator.locate() else { return }
        let ports = Stress.uiPorts, tmp = Stress.uiDir
        let clip = tmp.appendingPathComponent("feed.mp4")
        _ = shell(ff, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=60:duration=10", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=10",
                       "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-b:v", "8M", "-maxrate", "8M", "-bufsize", "4M", "-g", "60", "-bf", "0", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k", clip.path])
        var pubs: [Process] = []
        var ids: [String] = [], sinkName = ""
        for i in 0...n {
            guard let pair = try? await svc.createDevice(name: i == n ? "sink" : "Phone \(i + 1)") else { return }
            let base = "http://127.0.0.1:\(ports.studio)"
            func post(_ path: String, _ body: [String: Any]) async -> [String: Any] {
                var r = URLRequest(url: URL(string: base + path)!); r.httpMethod = "POST"
                r.setValue(pair.key, forHTTPHeaderField: "X-Device-Key"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try? JSONSerialization.data(withJSONObject: body)
                guard let (d, _) = try? await URLSession.shared.data(for: r) else { return [:] }
                return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
            }
            var ok = false
            for _ in 0..<50 { if !(await post("/api/device/hello", ["deviceModel": "iPhone15,2", "osVersion": "17.0", "appVersion": "1.0"])).isEmpty { ok = true; break }; try? await Task.sleep(nanoseconds: 100_000_000) }
            guard ok, let name = (await post("/api/device/stream/start", ["quality": "1080p", "fps": 60]))["streamName"] as? String else { say("STRESSUI: pairing failed"); return }
            if i == n { sinkName = name } else {
                ids.append(pair.device.id)
                let p = Process(); p.executableURL = URL(fileURLWithPath: ff)
                p.arguments = ["-v", "error", "-re", "-stream_loop", "-1", "-i", clip.path, "-c", "copy", "-f", "flv", "rtmp://127.0.0.1:\(ports.rtmp)/live/\(name)"]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                pubs.append(p)
            }
        }
        defer { pubs.forEach { $0.terminate() } }
        func ref(_ i: Int) -> SourceRef? { i < ids.count ? .device(id: ids[i]) : nil }
        let prog = n >= 3 ? Scene(id: "sp", name: "Stress trio", layout: .trio, slots: [ref(0), ref(1), ref(2)])
                 : n == 2 ? Scene(id: "sp", name: "Stress side", layout: .side, slots: [ref(0), ref(1)]) : Scene(id: "sp", name: "Stress full", layout: .full, slots: [ref(0)])
        let alt = n >= 3 ? Scene(id: "sa", name: "Stress alt", layout: .trio, slots: [ref(2), ref(0), ref(1)]) : Scene(id: "sa", name: "Stress alt", layout: .pip, slots: [ref(0), ref(min(1, n - 1))])
        await svc.saveScene(prog); await svc.saveScene(alt)
        svc.setPreview(sceneID: "sp"); svc.take(.cut)
        svc.setPreview(sceneID: "sa")
        model.refresh()
        pubs.forEach { try? $0.run() }
        let sources = ids.compactMap { svc.ingest.sourceProvider.phone($0) }
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 40 {
            if sources.count == n && sources.allSatisfy({ $0.metrics.decodedFPS > 20 }) { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let dest = Destination(id: "sinkd", name: "sink", kind: .custom, url: "rtmp://127.0.0.1:\(ports.rtmp)/live", key: sinkName)
        await svc.saveDestination(dest)
        do { try await svc.goLive(record: true, destinationIDs: ["sinkd"]) } catch { say("STRESSUI: go live failed \(error)"); return }
        model.refresh()
        say("--- UI mode, \(n) phones, live with recording + RTMP ---")
        try? await Task.sleep(nanoseconds: 8_000_000_000)

        do {   // cost of each AppModel.refresh() ingredient (main thread), 100 calls each
            func t(_ name: String, _ f: () -> Void) -> String { let a = CACurrentMediaTime(); for _ in 0..<100 { f() }; return String(format: "%@=%.3f", name, (CACurrentMediaTime() - a) * 10) }
            say("refresh parts (ms/call): " + [t("devices") { _ = svc.devices() }, t("scenes") { _ = svc.scenes() }, t("destinations") { _ = svc.destinations() }, t("stats") { _ = svc.stats() },
                  t("recordings") { _ = svc.recordings() }, t("props") { _ = svc.props() }, t("disk") { _ = svc.disk() }, t("refresh") { model.refresh() }].joined(separator: " "))
        }
        do {   // cost of one observed-property mutation on the main thread (SwiftUI invalidation), 20 tries spaced 100 ms apart
            func t(_ name: String, _ f: () -> Void) async -> String {
                var xs: [Double] = []
                for _ in 0..<20 { try? await Task.sleep(nanoseconds: 100_000_000); let a = CACurrentMediaTime(); f(); xs.append((CACurrentMediaTime() - a) * 1000) }
                xs.sort(); return String(format: "%@=%.2f/%.2f", name, xs[xs.count / 2], xs.last!)
            }
            var parts: [String] = []
            parts.append(await t("audioPeak") { model.audioPeak = Float.random(in: 0...1) })
            parts.append(await t("stats.fps") { model.stats.fps += 0.01 })
            parts.append(await t("recordings") { if !model.recordings.isEmpty { model.recordings[0].duration += 1 } })
            parts.append(await t("disk") { model.disk.freeBytes += 1 })
            parts.append(await t("svc.devices") { _ = svc.devices() })
            parts.append(await t("svc.scenes") { _ = svc.scenes() })
            parts.append(await t("svc.stats") { _ = svc.stats() })
            parts.append(await t("svc.recordings") { _ = svc.recordings() })
            parts.append(await t("svc.props") { _ = svc.props() })
            parts.append(await t("svc.disk") { _ = svc.disk() })
            parts.append(await t("svc.destinations") { _ = svc.destinations() })
            parts.append(await t("svc.studioName") { _ = svc.studioName; _ = svc.lanURL; _ = svc.slateText; _ = svc.introPropId })
            parts.append(await t("refresh()") { model.refresh() })
            say("mutation cost p50/max ms: " + parts.joined(separator: " "))
        }
        let gaps = Gaps()
        MonitorNSView.globalShow = { name, t in if name == "program" { gaps.add(t) } }
        let ticks = Gaps()
        let picks = PickLog(); FrameBox.dbgHook = { tg, ch, nw in picks.add(tg, ch, nw) }
        MonitorNSView.globalTick = { name, t in if name == "program" { ticks.add(t) } }
        let secs = Double(env["STUDIO_STRESS_SECS"] ?? "30") ?? 30
        let th0 = snapshotThreads(), wall0 = CACurrentMediaTime(), ru0 = rusageSeconds()
        let e0 = svc.engine.stats, o0 = svc.output.stats
        var worstP99 = 0.0, onAlt = false, lastFade = wall0, sec = 0, sampled = false
        var refreshMs: [Double] = []
        let end = wall0 + secs
        while CACurrentMediaTime() < end {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if env["STUDIO_STRESS_NOFADE"] == nil, CACurrentMediaTime() - lastFade >= 2.5 {
                onAlt.toggle(); svc.setPreview(sceneID: onAlt ? "sa" : "sp"); svc.take(.fade); lastFade = CACurrentMediaTime(); model.refresh()
            }
            if CACurrentMediaTime() - wall0 < Double(sec + 1) { continue }
            sec += 1
            worstP99 = max(worstP99, svc.engine.stats.frameP99Ms)
            let r0 = CACurrentMediaTime(); model.refresh(); refreshMs.append((CACurrentMediaTime() - r0) * 1000)
            if !sampled, sec >= Int(secs / 2), let dir = env["STUDIO_STRESS_SAMPLE"] {
                sampled = true
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let sp = Process(); sp.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                sp.arguments = ["\(getpid())", "5", "-file", "\(dir)/sample-ui\(n).txt"]; sp.standardOutput = FileHandle.nullDevice; sp.standardError = FileHandle.nullDevice
                try? sp.run()
            }
        }
        let wall = CACurrentMediaTime() - wall0
        let th1 = snapshotThreads(), ruPct = (rusageSeconds() - ru0) / wall * 100
        let e1 = svc.engine.stats, o1 = svc.output.stats, mg = gaps.summary(), tk = ticks.summary()
        say(picks.summary())
        say(String(format: "display link: %.1f ticks/s, target delta p50=%.1f p99=%.1f max=%.1f ms, >25ms=%d", tk.fps, tk.p50, tk.p99, tk.max, tk.over25))
        var mainTid: UInt64 = 0; pthread_threadid_np(nil, &mainTid)
        var rows: [(String, Double)] = []
        for (tid, b) in th1 { rows.append((tid == mainTid ? "MAIN" : (b.name.isEmpty ? "thread-\(tid)" : b.name), Double(b.ns &- (th0[tid]?.ns ?? 0)) / 1e9 / wall * 100)) }
        rows.sort { $0.1 > $1.1 }
        say("threads: " + rows.prefix(8).map { String(format: "%@=%.1f%%", $0.0, $0.1) }.joined(separator: " "))
        let mainPct = rows.first { $0.0 == "MAIN" }?.1 ?? 0
        let missed = e1.missedDeadlines - e0.missedDeadlines, held = e1.heldFrames - e0.heldFrames, dropped = o1.droppedFrames - o0.droppedFrames
        refreshMs.sort()
        say(String(format: "UIRESULT n=%d fps=%.1f missed=%d held=%d frameP99worst=%.2f gpuAvg=%.2f gpuP99=%.2f outDropped=%d encLat=%.1fms encFPS=%.1f kbps=%.0f appCPU=%.0f%% main=%.1f%% footprint=%.0fMB thermal=%d monitorShown=%.1f/s monGapP99=%.1f monMax=%.1f mon>25ms=%d refresh(ms) p50=%.2f max=%.2f",
                    n, Double(e1.frames - e0.frames) / wall, missed, held, worstP99, e1.gpuAvgMs, e1.gpuP99Ms, dropped, o1.encodeLatencyMs, o1.encodeFPS, o1.kbps,
                    ruPct, mainPct, physFootprintMB(), ProcessInfo.processInfo.thermalState.rawValue, mg.fps, mg.p99, mg.max, mg.over25, refreshMs.isEmpty ? 0 : refreshMs[refreshMs.count / 2], refreshMs.last ?? 0))
        await svc.stopLive()
        await svc.shutdown()
    }
}

final class PickLog: @unchecked Sendable {
    let lock = NSLock(); var rows: [(Double, Double, Double)] = []
    func add(_ a: Double, _ b: Double, _ c: Double) { lock.lock(); rows.append((a, b, c)); lock.unlock() }
    func summary() -> String {
        lock.lock(); let r = rows; lock.unlock()
        guard r.count > 10 else { return "picks: none" }
        var rep = 0, skip = 0, one = 0
        var ages: [Double] = []
        for i in 1..<r.count { let d = Int(((r[i].1 - r[i - 1].1) * 60).rounded()); if d == 0 { rep += 1 } else if d == 1 { one += 1 } else { skip += d - 1 }; ages.append((r[i].0 - r[i].1) * 1000) }
        ages.sort()
        return String(format: "picks: ticks=%d advance1=%d repeat=%d skippedFrames=%d | age at display p5=%.1f p50=%.1f p95=%.1f ms", r.count, one, rep, skip, ages[ages.count / 20], ages[ages.count / 2], ages[ages.count * 19 / 20])
    }
}
