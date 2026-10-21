import Foundation

let deviceOnlineWindow: TimeInterval = 30
let maxDevices = 50
let deviceKeyInvalidMessage = "This key doesn't work. Add the phone again in 7XEN Studio → Phones."

struct APIError: Error {
    var status: Int, code: String, message: String, fields: [String: String]? = nil
    static func notFound(_ m: String = "Not found") -> APIError { .init(status: 404, code: "NOT_FOUND", message: m) }
    static func bad(_ m: String, _ f: [String: String]? = nil) -> APIError { .init(status: 400, code: "VALIDATION_ERROR", message: m, fields: f) }
}

/// What the manager needs from MediaMTX (control API). Faked in tests.
protocol MediaControl: AnyObject {
    func pathReady(_ path: String) async -> Date?
    func kick(_ path: String) async
}

/// Live (heartbeat) state of one phone, for the UI.
struct DeviceStatus: Identifiable, Hashable {
    var id: String
    var name: String
    var model: String?, osVersion: String?, appVersion: String?
    var lastSeenAt: Date?
    var online = false
    var streaming = false
    var videoReady = false
    var streamingSince: Date?
    var battery: Double?     // 0...1
    var charging: Bool?
    var thermal: String?
    var fps: Double?, bitrateKbps: Double?
    var width: Int?, height: Int?
    var network: String?
}

/// Port of devices.ts: phone API logic, heartbeat state (memory only), snapshot requests.
final class DeviceManager: @unchecked Sendable {
    struct Live { var lastSeenAt: Date; var state: String = "IDLE"; var streamingSince: Date?; var health: [String: Any] = [:] }
    private struct Pending { var id: String; var deviceId: String; var at: Date; var sent = false; var cont: CheckedContinuation<Data?, Never>? }

    let store: StudioStore, tokens: Tokens
    weak var media: MediaControl?
    var lanHost: String
    var rtmpPort: Int
    var now: () -> Date
    private var live: [String: Live] = [:]
    private var snapshots: [String: Pending] = [:]
    private let lock = NSLock()

    init(store: StudioStore, tokens: Tokens, media: MediaControl? = nil, lanHost: String = "127.0.0.1", rtmpPort: Int = 1940, now: @escaping () -> Date = Date.init) {
        self.store = store; self.tokens = tokens; self.media = media; self.lanHost = lanHost; self.rtmpPort = rtmpPort; self.now = now
    }

    func fromKey(_ key: String?) throws -> StoredDevice {
        let k = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.hasPrefix(deviceKeyPrefix), k.count <= 100, let d = store.device(byKey: k) else {
            throw APIError(status: 401, code: "DEVICE_KEY_INVALID", message: deviceKeyInvalidMessage)
        }
        return d
    }

    @discardableResult private func touch(_ id: String) -> Live {
        lock.lock(); defer { lock.unlock() }
        var l = live[id] ?? Live(lastSeenAt: now())
        l.lastSeenAt = now(); live[id] = l; return l
    }
    private func mutate(_ id: String, _ f: (inout Live) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var l = live[id] ?? Live(lastSeenAt: now()); f(&l); live[id] = l
    }

    func hello(_ dev: StoredDevice, model: String?, osVersion: String?, appVersion: String?) -> [String: Any] {
        touch(dev.id)
        let stamp = isoNow(now())
        store.update { doc in
            if let i = doc.devices.firstIndex(where: { $0.id == dev.id }) {
                doc.devices[i].model = model ?? doc.devices[i].model
                doc.devices[i].osVersion = osVersion ?? doc.devices[i].osVersion
                doc.devices[i].appVersion = appVersion ?? doc.devices[i].appVersion
                doc.devices[i].lastHelloAt = stamp
            }
        }
        let name = store.studioName
        return ["device": ["id": dev.id, "name": dev.name], "manager": ["name": name], "studio": ["name": name], "assignedMatch": NSNull()]
    }

    func heartbeat(_ dev: StoredDevice, _ input: [String: Any]) -> [String: Any] {
        let t = now()
        lock.lock()
        let prev = live[dev.id]
        lock.unlock()
        let wasLive = prev.map { $0.state == "LIVE" && t.timeIntervalSince($0.lastSeenAt) <= deviceOnlineWindow } ?? false
        let state = (input["state"] as? String) ?? prev?.state ?? "IDLE"
        var health: [String: Any] = [:]
        for k in ["state", "quality", "autoDowngraded", "battery", "charging", "thermal", "cpuPct", "memMB", "fps", "bitrateKbps", "width", "height", "network"] {
            if let v = input[k] { health[k] = v }
        }
        mutate(dev.id) { l in
            l.lastSeenAt = t; l.state = state
            l.streamingSince = state == "LIVE" ? (wasLive ? (prev?.streamingSince ?? t) : t) : nil
            l.health = health
        }
        return ["assignedMatch": NSNull(), "snapshotRequests": takeSnapshotRequests(dev.id).map { ["id": $0] }]
    }

    func streamStart(_ dev: StoredDevice) -> [String: Any] {
        touch(dev.id)
        let (token, exp) = tokens.publishToken(deviceId: dev.id, keyHash: dev.keyHash, now: now())
        return ["rtmpUrl": "rtmp://\(lanHost):\(rtmpPort)/live", "streamName": "dev_\(dev.id)?token=\(token)", "expiresAt": isoNow(exp)]
    }

    func streamStop(_ dev: StoredDevice) { touch(dev.id); mutate(dev.id) { $0.state = "IDLE"; $0.streamingSince = nil } }

    // snapshots
    private func sweep() {
        let t = now()
        for (k, p) in snapshots where t.timeIntervalSince(p.at) > 20 { snapshots[k] = nil; p.cont?.resume(returning: nil) }
    }
    func takeSnapshotRequests(_ deviceId: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        sweep()
        var out: [String] = []
        for (k, var p) in snapshots where p.deviceId == deviceId && !p.sent { p.sent = true; snapshots[k] = p; out.append(k) }
        return out
    }
    private func addPending(_ p: Pending) { lock.lock(); snapshots[p.id] = p; lock.unlock() }
    private func removePending(_ id: String) -> Pending? { lock.lock(); defer { lock.unlock() }; return snapshots.removeValue(forKey: id) }
    func fulfilSnapshot(deviceId: String, requestId: String, png: Data) -> Bool {
        lock.lock()
        guard let p = snapshots[requestId], p.deviceId == deviceId else { lock.unlock(); return false }
        snapshots[requestId] = nil
        lock.unlock()
        p.cont?.resume(returning: png); return true
    }
    /// Ask the phone for a full-quality screenshot (rides on its next heartbeat reply); nil after `wait` seconds.
    func requestSnapshot(_ deviceId: String, wait: TimeInterval = 5) async -> Data? {
        let id = UUID().uuidString.lowercased()
        return await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            addPending(Pending(id: id, deviceId: deviceId, at: now(), cont: c))
            DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                let p = self.removePending(id)
                p?.cont?.resume(returning: nil)
            }
        }
    }

    private func mutateRemove(_ id: String) { lock.lock(); live[id] = nil; lock.unlock() }
    private func liveState(_ id: String) -> Live? { lock.lock(); defer { lock.unlock() }; return live[id] }
    // UI
    func status(_ dev: StoredDevice) async -> DeviceStatus {
        let ready = await media?.pathReady(devicePath(dev.id))
        let l = liveState(dev.id)
        let t = now()
        let online = l.map { t.timeIntervalSince($0.lastSeenAt) <= deviceOnlineWindow } ?? false
        let streaming = ready != nil || (online && l?.state == "LIVE")
        let h = online ? (l?.health ?? [:]) : [:]
        func num(_ k: String) -> Double? { (h[k] as? NSNumber)?.doubleValue }
        return DeviceStatus(id: dev.id, name: dev.name, model: dev.model, osVersion: dev.osVersion, appVersion: dev.appVersion,
                            lastSeenAt: l?.lastSeenAt, online: online, streaming: streaming, videoReady: ready != nil,
                            streamingSince: streaming ? (l?.state == "LIVE" ? l?.streamingSince : ready) : nil,
                            battery: num("battery"), charging: h["charging"] as? Bool, thermal: h["thermal"] as? String,
                            fps: num("fps"), bitrateKbps: num("bitrateKbps"), width: num("width").map(Int.init), height: num("height").map(Int.init),
                            network: h["network"] as? String)
    }
    func statuses() async -> [DeviceStatus] {
        var out: [DeviceStatus] = []
        for d in store.devices { out.append(await status(d)) }
        return out
    }

    /// Adds a phone. `key` is shown once.
    func create(name: String) throws -> (device: StoredDevice, key: String, pairURL: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...40).contains(n.count) else { throw APIError.bad("Please check your input: At least 2 characters", ["name": "At least 2 characters"]) }
        guard store.devices.count < maxDevices else { throw APIError(status: 409, code: "CONFLICT", message: "You can add up to \(maxDevices) phones. Remove one first.") }
        let key = newDeviceKey()
        let d = StoredDevice(id: newId("d"), name: n, keyHash: sha256Hex(key), createdAt: isoNow(now()))
        store.update { $0.devices.append(d) }
        return (d, key, pairURL(host: "http://\(lanHost):\(studioPort)", key: key, name: store.studioName))
    }
    var studioPort = 4400
    func rename(_ id: String, name: String) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...40).contains(n.count) else { throw APIError.bad("At least 2 characters") }
        guard store.device(id) != nil else { throw APIError.notFound("Phone not found") }
        store.update { doc in if let i = doc.devices.firstIndex(where: { $0.id == id }) { doc.devices[i].name = n } }
    }
    func remove(_ id: String) async throws {
        guard store.device(id) != nil else { throw APIError.notFound("Phone not found") }
        store.update { $0.devices.removeAll { $0.id == id } }
        mutateRemove(id)
        await media?.kick(devicePath(id))
    }
}

func pairURL(host: String, key: String, name: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
    func e(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
    return "7xen://pair?host=\(e(host))&key=\(e(key))&name=\(e(name))"
}
