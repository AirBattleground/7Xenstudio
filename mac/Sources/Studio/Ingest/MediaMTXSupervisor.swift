import Foundation
import Combine

struct MediaMTXPorts { var studio = 4400, rtmp = 1940, hls = 8893, api = 9994 }

/// mediamtx.yml adapted from ../mediamtx.yml (ports + auth hook address are parameters).
func mediaMTXConfig(_ p: MediaMTXPorts = MediaMTXPorts()) -> String {
    """
    # 7XEN Studio: MediaMTX receives the phones' RTMP over the venue Wi-Fi and serves LL-HLS to the studio app (same Mac).
    # Every publish/read is checked by the studio app (POST /internal/media/auth).
    logLevel: info
    logDestinations: [stdout]

    authMethod: http
    authHTTPAddress: http://127.0.0.1:\(p.studio)/internal/media/auth
    authHTTPExclude:
      - action: metrics
      - action: pprof

    api: yes
    apiAddress: 127.0.0.1:\(p.api)

    rtmp: yes
    rtmpAddress: :\(p.rtmp)
    rtmpEncryption: "no"

    hls: yes
    hlsAddress: 127.0.0.1:\(p.hls)
    hlsAlwaysRemux: yes
    hlsVariant: lowLatency
    hlsPartDuration: 200ms
    hlsSegmentCount: 7
    hlsSegmentDuration: 1s
    hlsAllowOrigin: ""

    rtsp: no
    webrtc: no
    srt: no
    moq: no

    paths:
      "~^live/(dev|show)_[A-Za-z0-9]{8,40}$":
        source: publisher
    """
}

/// Runs the mediamtx child process and restarts it when it dies. Also the `MediaControl` (control API) client.
final class MediaMTXSupervisor: ObservableObject, MediaControl, @unchecked Sendable {
    enum State: Equatable { case stopped, running, restarting, missingBinary }
    @Published private(set) var state: State = .stopped
    let ports: MediaMTXPorts
    let dir: URL
    let tokens: Tokens
    var binaryOverride: URL?
    private var process: Process?
    private var wantRunning = false
    private let lock = NSLock()
    private var failures = 0

    init(dir: URL, tokens: Tokens, ports: MediaMTXPorts = MediaMTXPorts()) { self.dir = dir; self.tokens = tokens; self.ports = ports }

    static func findBinary() -> URL? {
        var c: [String] = []
        if let r = Bundle.main.resourceURL { c.append(r.appendingPathComponent("mediamtx").path) }
        if let e = Bundle.main.executableURL { c.append(e.deletingLastPathComponent().appendingPathComponent("mediamtx").path) }
        c += ["/opt/homebrew/bin/mediamtx", "/usr/local/bin/mediamtx"]
        c += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/mediamtx" }
        return c.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private func set(_ s: State) { DispatchQueue.main.async { self.state = s } }

    func start() {
        lock.lock(); wantRunning = true; lock.unlock()
        launch()
    }

    private var pidFile: URL { dir.appendingPathComponent("mediamtx.pid") }

    private func launch() {
        lock.lock(); defer { lock.unlock() }
        guard wantRunning, process == nil else { return }
        guard let bin = binaryOverride ?? Self.findBinary() else { set(.missingBinary); return }
        // a mediamtx left over from a crashed run would hold the ports
        if let s = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
            let ps = Process(); ps.executableURL = URL(fileURLWithPath: "/bin/ps"); ps.arguments = ["-p", "\(pid)", "-o", "comm="]
            let pipe = Pipe(); ps.standardOutput = pipe
            if (try? ps.run()) != nil {
                ps.waitUntilExit()
                if String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("mediamtx") { kill(pid, SIGTERM); usleep(300_000) }
            }
        }
        let cfg = dir.appendingPathComponent("mediamtx.yml")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? writeAtomic(cfg, Data(mediaMTXConfig(ports).utf8))
        let log = dir.appendingPathComponent("mediamtx.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let p = Process()
        p.executableURL = bin; p.arguments = [cfg.path]; p.currentDirectoryURL = dir
        if let fh = try? FileHandle(forWritingTo: log) { fh.seekToEndOfFile(); p.standardOutput = fh; p.standardError = fh }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.lock.lock()
            if self.process === proc { self.process = nil }
            let again = self.wantRunning
            self.failures += 1
            let delay = min(10.0, 0.5 * Double(self.failures))
            self.lock.unlock()
            if again {
                self.set(.restarting)
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { self.launch() }
            } else { self.set(.stopped) }
        }
        do {
            try p.run()
            process = p
            try? Data("\(p.processIdentifier)".utf8).write(to: pidFile)
            set(.running)
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.lock.lock(); if self?.process === p { self?.failures = 0 }; self?.lock.unlock()
            }
        } catch {
            set(.restarting)
            failures += 1
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.launch() }
        }
    }

    func stop() {
        lock.lock(); wantRunning = false; let p = process; lock.unlock()
        p?.terminate()
        try? FileManager.default.removeItem(at: pidFile)
        set(.stopped)
    }

    // MARK: control API (MediaControl)
    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(ports.api)\(path)")!, timeoutInterval: 3)
        r.httpMethod = method; r.setValue(tokens.internalAuthHeader, forHTTPHeaderField: "Authorization"); return r
    }
    func pathReady(_ path: String) async -> Date? {
        let enc = path.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? path
        guard let (data, resp) = try? await URLSession.shared.data(for: request("/v3/paths/get/\(enc)")),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], o["ready"] as? Bool == true else { return nil }
        if let t = o["readyTime"] as? String {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: t) ?? ISO8601DateFormatter().date(from: t) { return d }
        }
        return Date()
    }
    func kick(_ path: String) async {
        guard let (data, resp) = try? await URLSession.shared.data(for: request("/v3/rtmpconns/list?itemsPerPage=1000")),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = o["items"] as? [[String: Any]] else { return }
        for it in items where it["path"] as? String == path {
            if let id = it["id"] as? String { _ = try? await URLSession.shared.data(for: request("/v3/rtmpconns/kick/\(id)", method: "POST")) }
        }
    }
}
