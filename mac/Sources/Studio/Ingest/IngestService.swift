import Foundation
import Darwin

/// Everything the UI needs from Core + Ingest. Create once; call `start()` at launch and `stop()` at quit.
final class IngestService {
    let store: StudioStore
    let tokens: Tokens
    let devices: DeviceManager
    let supervisor: MediaMTXSupervisor
    let sourceProvider: IngestSourceProvider
    let router: StudioRouter
    let server: HTTPServer
    let ports: MediaMTXPorts
    private(set) var lastError: String?

    init(dir: URL = StudioStore.defaultDirectory, ports: MediaMTXPorts = MediaMTXPorts()) throws {
        self.ports = ports
        sourceProvider = IngestSourceProvider(hlsPort: ports.hls)
        sourceProvider.rtmpPort = ports.rtmp
        sourceProvider.ffmpegPath = FFmpegLocator.locate()
        store = try StudioStore(dir: dir)
        tokens = Tokens(secret: store.secret)
        let st = store
        sourceProvider.propResolver = { id in st.propURL(id).flatMap { u in st.props.first { $0.id == id }.map { (u, $0.kind) } } }
        sourceProvider.webCacheDir = dir.appendingPathComponent("web-cache")
        supervisor = MediaMTXSupervisor(dir: dir, tokens: tokens, ports: ports)
        devices = DeviceManager(store: store, tokens: tokens, media: supervisor, lanHost: Self.lanIPv4() ?? "127.0.0.1", rtmpPort: ports.rtmp)
        devices.studioPort = ports.studio
        router = StudioRouter(store: store, devices: devices, tokens: tokens)
        let r = router
        server = HTTPServer(port: UInt16(ports.studio)) { await r.handle($0) }
    }

    /// http://<lan ip>:4400
    var lanURL: String { "http://\(devices.lanHost):\(ports.studio)" }

    func start() {
        do { try server.start() } catch { lastError = "Could not listen on port \(ports.studio): \(error.localizedDescription)" }
        server.onError = { [weak self] e in self?.lastError = e.localizedDescription }
        supervisor.start()
    }
    func stop() { sourceProvider.stopAll(); server.stop(); supervisor.stop() }

    /// Primary LAN IPv4 (en0 first).
    static func lanIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var found: [(String, String)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let a = p.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), (p.pointee.ifa_flags & UInt32(IFF_UP)) != 0, (p.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(a, socklen_t(a.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            found.append((String(cString: p.pointee.ifa_name), String(cString: buf)))
        }
        return (found.first { $0.0 == "en0" } ?? found.first { $0.0.hasPrefix("en") } ?? found.first)?.1
    }
}
