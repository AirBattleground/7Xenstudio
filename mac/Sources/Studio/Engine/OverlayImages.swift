// Decoded images for the logo / web overlays. Prop files load once; URLs are re-fetched every `pollInterval` seconds.
// Loading happens off the render thread; `image(...)` never blocks and returns nil until the first load completes.
import Foundation
import CoreGraphics
import ImageIO

final class OverlayImageCache: @unchecked Sendable {
    struct Loaded { var image: CGImage; var version: Int }
    var propResolver: (@Sendable (String) -> URL?)? {
        get { lock.withLock { _resolver } } set { lock.withLock { _resolver = newValue } }
    }
    var pollInterval: TimeInterval = 2

    private struct Entry { var image: CGImage?; var version = 0; var loading = false; var fetched = Date.distantPast; var used = Date(); var digest = 0 }
    private var entries: [String: Entry] = [:]
    private var _resolver: (@Sendable (String) -> URL?)?
    private let lock = NSLock()
    private let group = DispatchGroup()
    private let queue = DispatchQueue(label: "overlay.images", qos: .utility, attributes: .concurrent)

    func image(propId: String) -> Loaded? { get(key: "p:" + propId, poll: false) { [weak self] in self?.propResolver?(propId) } }
    func image(url: String) -> Loaded? {
        let t = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), ["http", "https", "file"].contains(u.scheme?.lowercased() ?? "") else { return nil }
        return get(key: "u:" + t, poll: !u.isFileURL) { u }
    }

    /// Blocks until in-flight loads finish (tests).
    func waitIdle(timeout: TimeInterval = 5) { _ = group.wait(timeout: .now() + timeout) }

    private func get(key: String, poll: Bool, url: () -> URL?) -> Loaded? {
        let now = Date()
        var start = false
        let result: Loaded?
        lock.lock()
        var e = entries[key] ?? Entry()
        e.used = now
        if !e.loading && (e.image == nil ? now.timeIntervalSince(e.fetched) > (poll ? pollInterval : 1) : (poll && now.timeIntervalSince(e.fetched) >= pollInterval)) {
            e.loading = true; e.fetched = now; start = true
        }
        entries[key] = e
        if entries.count > 8 { for (k, v) in entries where k != key && now.timeIntervalSince(v.used) > 5 { entries[k] = nil } }
        result = e.image.map { Loaded(image: $0, version: e.version) }
        lock.unlock()
        if start {
            guard let u = url() else { finish(key, data: nil); return result }
            group.enter()
            queue.async { [self] in
                defer { group.leave() }
                if u.isFileURL { finish(key, data: try? Data(contentsOf: u)) }
                else {
                    var req = URLRequest(url: u); req.timeoutInterval = 5; req.cachePolicy = .reloadIgnoringLocalCacheData
                    group.enter()
                    URLSession.shared.dataTask(with: req) { [self] d, resp, _ in
                        defer { group.leave() }
                        let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                        finish(key, data: ok ? d : nil)
                    }.resume()
                }
            }
        }
        return result
    }

    private func finish(_ key: String, data: Data?) {
        var img: CGImage?
        var digest = 0
        if let data, let src = CGImageSourceCreateWithData(data as CFData, nil) {
            img = CGImageSourceCreateImageAtIndex(src, 0, nil)
            digest = data.hashValue
        }
        lock.lock()
        if var e = entries[key] {
            e.loading = false
            if let img, digest != e.digest || e.image == nil { e.image = img; e.digest = digest; e.version += 1 }   // keep last good on failure
            entries[key] = e
        }
        lock.unlock()
    }
}
