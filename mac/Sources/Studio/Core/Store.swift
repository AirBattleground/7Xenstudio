import Foundation
import Combine

struct StoredDevice: Codable, Identifiable, Hashable {
    var id: String; var name: String
    /// sha256 of the key (the key itself is shown once and never stored)
    var keyHash: String
    var createdAt: String
    var model: String?, osVersion: String?, appVersion: String?, lastHelloAt: String?
    /// additive: rotation in degrees (0/90/180/270) and horizontal flip chosen by the operator; nil rotation = automatic (phone-reported, else none)
    var rotation: Int? = nil
    var flip: Bool? = nil
}
struct StoredProp: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case video, image }
    var id: String; var name: String; var kind: Kind; var sizeBytes: Int64; var file: String; var createdAt: String
}
struct StudioShow: Codable, Identifiable, Hashable {
    var id: String; var name: String; var scenes: [Scene]; var overlays: Overlays; var createdAt: String
    /// additive: the AirBattleground match this show covers (Integrations/AirBattleground); no secrets
    var link: ShowLink? = nil
}
struct StudioSettings: Codable, Hashable { var name: String? = nil; var slateText: String? = nil; var introPropId: String? = nil
    /// additive (Audio): mixer + commentary settings
    var audio: AudioSettings? = nil
    /// additive (Output/Engine): video bitrate (kbps), HEVC local recording, "Vivid" final-pass enhancement (VividLevel raw value; nil = subtle)
    var videoKbps: Int? = nil
    var recordHEVC: Bool? = nil
    var vivid: Int? = nil }

struct StoreDoc: Codable {
    var devices: [StoredDevice] = []
    var destinations: [Destination] = []
    var scenes: [Scene] = []
    var shows: [StudioShow] = []
    var props: [StoredProp] = []
    var settings = StudioSettings()
    var activeShowId: String? = nil
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        devices = (try? c.decode([StoredDevice].self, forKey: .devices)) ?? []
        destinations = (try? c.decode([Destination].self, forKey: .destinations)) ?? []
        scenes = (try? c.decode([Scene].self, forKey: .scenes)) ?? []
        shows = (try? c.decode([StudioShow].self, forKey: .shows)) ?? []
        props = (try? c.decode([StoredProp].self, forKey: .props)) ?? []
        settings = (try? c.decode(StudioSettings.self, forKey: .settings)) ?? StudioSettings()
        activeShowId = (try? c.decodeIfPresent(String.self, forKey: .activeShowId)) ?? nil
    }
}

func isoNow(_ date: Date = Date()) -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

func writeAtomic(_ url: URL, _ data: Data, mode: Int? = nil) throws {
    let tmp = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(randomHex(bytes: 4)).tmp")
    try data.write(to: tmp)
    if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path) }
    if FileManager.default.fileExists(atPath: url.path) {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    } else {
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}

/// JSON store in ~/Library/Application Support/7XEN Studio. Thread-safe; mutate through `update`.
final class StudioStore: ObservableObject, @unchecked Sendable {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("7XEN Studio")
    }
    let dir: URL, propsDir: URL, recordingsDir: URL
    let secret: Data
    private var doc: StoreDoc
    private let lock = NSLock()
    private let file: URL

    init(dir: URL = StudioStore.defaultDirectory) throws {
        self.dir = dir
        propsDir = dir.appendingPathComponent("props"); recordingsDir = dir.appendingPathComponent("recordings")
        let fm = FileManager.default
        for d in [dir, propsDir, recordingsDir] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let secretFile = dir.appendingPathComponent("secret")
        if !fm.fileExists(atPath: secretFile.path) { try writeAtomic(secretFile, Data(randomHex(bytes: 32).utf8), mode: 0o600) }
        let hex = (try String(contentsOf: secretFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        var bytes = Data(); var i = hex.startIndex
        while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), let b = UInt8(hex[i..<j], radix: 16) { bytes.append(b); i = j }
        guard bytes.count >= 16 else { throw CoreError(message: "\(secretFile.path) is damaged: delete it (phones must then be added again)") }
        secret = bytes
        file = dir.appendingPathComponent("store.json")
        if let data = try? Data(contentsOf: file) { doc = (try? JSONDecoder().decode(StoreDoc.self, from: data)) ?? StoreDoc() } else { doc = StoreDoc() }
    }

    var snapshot: StoreDoc { lock.lock(); defer { lock.unlock() }; return doc }
    var devices: [StoredDevice] { snapshot.devices.sorted { $0.createdAt < $1.createdAt } }
    var destinations: [Destination] { snapshot.destinations }
    var scenes: [Scene] { snapshot.scenes }
    var shows: [StudioShow] { snapshot.shows }
    var props: [StoredProp] { snapshot.props.sorted { $0.createdAt > $1.createdAt } }
    var settings: StudioSettings { snapshot.settings }

    func device(_ id: String) -> StoredDevice? { snapshot.devices.first { $0.id == id } }
    func device(byKey key: String) -> StoredDevice? { let h = sha256Hex(key); return snapshot.devices.first { $0.keyHash == h } }

    /// Mutate and persist atomically. Returns the closure's result.
    @discardableResult
    func update<T>(_ body: (inout StoreDoc) throws -> T) rethrows -> T {
        lock.lock()
        let r: T
        do { r = try body(&doc) } catch { lock.unlock(); throw error }
        let data = try? JSONEncoder.pretty.encode(doc)
        lock.unlock()
        if let data { try? writeAtomic(file, data) }
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        return r
    }

    // destinations
    func upsert(_ d: Destination) { update { doc in if let i = doc.destinations.firstIndex(where: { $0.id == d.id }) { doc.destinations[i] = d } else { doc.destinations.append(d) } } }
    func removeDestination(_ id: String) { update { $0.destinations.removeAll { $0.id == id } } }
    // scenes
    func upsert(_ s: Scene) { update { doc in if let i = doc.scenes.firstIndex(where: { $0.id == s.id }) { doc.scenes[i] = s } else { doc.scenes.append(s) } } }
    func removeScene(_ id: String) { update { $0.scenes.removeAll { $0.id == id } } }
    // shows
    func upsert(_ s: StudioShow) { update { doc in if let i = doc.shows.firstIndex(where: { $0.id == s.id }) { doc.shows[i] = s } else { doc.shows.append(s) } } }
    func removeShow(_ id: String) { update { $0.shows.removeAll { $0.id == id } } }
    func createShow(name: String) -> StudioShow {
        let first = devices.first?.id
        let show = StudioShow(id: newId("s"), name: name, scenes: defaultScenes(firstDeviceId: first), overlays: Overlays(), createdAt: isoNow())
        upsert(show); return show
    }
    // overlays per show (writes are debounced; reads see pending values)
    private var pendingOverlays: [String: Overlays] = [:]
    private var overlayFlush: DispatchWorkItem?
    var overlayDebounce: TimeInterval = 0.4

    /// The show the app is running; created on first use.
    func ensureActiveShow() -> StudioShow {
        if let id = snapshot.activeShowId, let s = snapshot.shows.first(where: { $0.id == id }) { return s }
        if let s = snapshot.shows.first { update { $0.activeShowId = s.id }; return s }
        let s = createShow(name: "My show"); update { $0.activeShowId = s.id }; return s
    }
    func overlays(forShow id: String) -> Overlays {
        lock.lock(); defer { lock.unlock() }
        return pendingOverlays[id] ?? doc.shows.first { $0.id == id }?.overlays ?? Overlays()
    }
    func saveOverlays(_ o: Overlays, forShow id: String) {
        lock.lock()
        pendingOverlays[id] = o
        overlayFlush?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flushOverlays() }
        overlayFlush = w
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + overlayDebounce, execute: w)
    }
    /// Writes any pending overlay changes now (also call before quitting).
    func flushOverlays() {
        lock.lock(); let p = pendingOverlays; pendingOverlays = [:]; overlayFlush?.cancel(); overlayFlush = nil; lock.unlock()
        guard !p.isEmpty else { return }
        update { doc in for (id, o) in p { if let i = doc.shows.firstIndex(where: { $0.id == id }) { doc.shows[i].overlays = o } } }
    }

    func setStudioName(_ n: String) { update { $0.settings.name = n } }
    func setSlateText(_ t: String) { update { $0.settings.slateText = t } }
    func setIntroProp(_ id: String?) { update { $0.settings.introPropId = id } }
    func setAudio(_ a: AudioSettings) { update { $0.settings.audio = a } }
    func setVideoKbps(_ k: Int) { update { $0.settings.videoKbps = k } }
    func setRecordHEVC(_ on: Bool) { update { $0.settings.recordHEVC = on } }
    func setVivid(_ v: VividLevel) { update { $0.settings.vivid = v.rawValue } }
    var videoKbps: Int { settings.videoKbps ?? defaultVideoKbps }
    var vivid: VividLevel { settings.vivid.flatMap(VividLevel.init(rawValue:)) ?? .subtle }
    func setDeviceTransform(_ id: String, rotation: Int?, flip: Bool?) {
        update { doc in if let i = doc.devices.firstIndex(where: { $0.id == id }) { doc.devices[i].rotation = rotation; doc.devices[i].flip = flip } }
    }
    func renameProp(_ id: String, name: String) {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !n.isEmpty else { return }
        update { doc in if let i = doc.props.firstIndex(where: { $0.id == id }) { doc.props[i].name = n } }
    }
    var studioName: String { settings.name ?? Host.current().localizedName ?? "7XEN Studio" }

    // props (files in propsDir)
    static let maxProps = 200
    func addProp(file src: URL, name: String? = nil) throws -> StoredProp {
        guard props.count < Self.maxProps else { throw CoreError(message: "You can keep up to \(Self.maxProps) props. Delete some first.") }
        let ext = src.pathExtension.lowercased()
        let images = ["png", "jpg", "jpeg", "webp", "gif"], videos = ["mp4", "m4v", "mov", "webm"]
        let kind: StoredProp.Kind
        if images.contains(ext) { kind = .image } else if videos.contains(ext) { kind = .video }
        else { throw CoreError(message: "Only videos (MP4, WebM, MOV) or images (PNG, JPEG, WebP, GIF)") }
        let size = (try FileManager.default.attributesOfItem(atPath: src.path)[.size] as? Int64) ?? 0
        if size > (kind == .video ? 500 : 10) * 1024 * 1024 { throw CoreError(message: kind == .video ? "Videos can be up to 500 MB" : "Images can be up to 10 MB") }
        let id = newId("p"), fname = "\(id).\(ext)"
        try FileManager.default.copyItem(at: src, to: propsDir.appendingPathComponent(fname))
        let nm = String((name?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? src.deletingPathExtension().lastPathComponent).prefix(60)
        let p = StoredProp(id: id, name: String(nm), kind: kind, sizeBytes: size, file: fname, createdAt: isoNow())
        update { $0.props.append(p) }
        return p
    }
    func propURL(_ id: String) -> URL? { snapshot.props.first { $0.id == id }.map { propsDir.appendingPathComponent($0.file) } }
    func removeProp(_ id: String) {
        if let u = propURL(id) { try? FileManager.default.removeItem(at: u) }
        update { $0.props.removeAll { $0.id == id } }
    }
}

extension JSONEncoder { static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e } }

func defaultScenes(firstDeviceId: String?) -> [Scene] {
    [Scene(id: "starting", name: "Starting soon", layout: .full, slots: [.slate]),
     Scene(id: "phone", name: "Phone", layout: .full, slots: [firstDeviceId.map { .device(id: $0) }]),
     Scene(id: "host", name: "Host", layout: .full, slots: [.camera]),
     Scene(id: "break", name: "Break", layout: .full, slots: [.slate])]
}

func slugify(_ s: String) -> String {
    let folded = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
    var out = ""; var dash = false
    for ch in folded.unicodeScalars {
        if (ch.value >= 97 && ch.value <= 122) || (ch.value >= 48 && ch.value <= 57) { out.unicodeScalars.append(ch); dash = false }
        else if !dash && !out.isEmpty { out.append("-"); dash = true }
    }
    while out.hasSuffix("-") { out.removeLast() }
    let r = String(out.prefix(40))
    return r.isEmpty ? "show" : r
}

/// rtmp://host/app + key -> rtmp://host/app/key
func joinStreamKey(_ url: String, _ key: String) -> String {
    var u = url.trimmingCharacters(in: .whitespacesAndNewlines); while u.hasSuffix("/") { u.removeLast() }
    var k = key.trimmingCharacters(in: .whitespacesAndNewlines); while k.hasPrefix("/") { k.removeFirst() }
    return "\(u)/\(k)"
}

struct CoreError: LocalizedError { var message: String; var errorDescription: String? { message } }
