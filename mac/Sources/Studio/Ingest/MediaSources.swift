import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
import ImageIO
import QuartzCore

/// Builds an IOSurface/Metal-compatible BGRA pixel buffer from a CGImage (fit inside maxSide).
func makeBGRAPixelBuffer(from image: CGImage, maxSide: Int = 3840) -> CVPixelBuffer? {
    var w = image.width, h = image.height
    guard w > 0, h > 0 else { return nil }
    let big = max(w, h)
    if big > maxSide { let s = Double(maxSide) / Double(big); w = max(1, Int(Double(w) * s)); h = max(1, Int(Double(h) * s)) }
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](), kCVPixelBufferMetalCompatibilityKey: true]
    guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return pb
}

func decodeImage(_ data: Data) -> CGImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
}

/// A still image prop (file on disk) or a web image (URL, re-downloaded every `refresh` seconds, last good frame kept).
final class ImageSource: FrameSource, @unchecked Sendable {
    let ref: SourceRef
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private(set) var fetchError: String?
    private let queue = DispatchQueue(label: "image.source", qos: .utility)

    init(ref: SourceRef, file: URL) {
        self.ref = ref
        if let d = try? Data(contentsOf: file), let img = decodeImage(d) { frame = makeBGRAPixelBuffer(from: img) }
    }

    init(ref: SourceRef, webURL: URL, cacheDir: URL, refresh: TimeInterval = 2) {
        self.ref = ref
        let cache = cacheDir.appendingPathComponent(sha256Hex(webURL.absoluteString) + ".img")
        if let d = try? Data(contentsOf: cache), let img = decodeImage(d) { frame = makeBGRAPixelBuffer(from: img) }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: refresh)
        var inflight = false
        t.setEventHandler { [weak self] in
            guard let self, !self.isStopped, !inflight else { return }
            inflight = true
            var req = URLRequest(url: webURL); req.timeoutInterval = 8; req.cachePolicy = .reloadIgnoringLocalCacheData
            URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
                inflight = false
                guard let self else { return }
                if let data, (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true, let img = decodeImage(data), let pb = makeBGRAPixelBuffer(from: img) {
                    self.lock.lock(); self.frame = pb; self.fetchError = nil; self.lock.unlock()
                    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                    try? data.write(to: cache)
                } else {
                    self.lock.lock(); self.fetchError = err?.localizedDescription ?? "Not an image"; self.lock.unlock()
                }
            }.resume()
        }
        t.resume(); timer = t
    }

    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func latestFrame() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return frame }
    func stop() { lock.lock(); stopped = true; lock.unlock(); timer?.cancel(); timer = nil }
    deinit { timer?.cancel() }
}

/// A video prop: looping AVQueuePlayer, newest decoded frame via AVPlayerItemVideoOutput (muted).
final class VideoFileSource: FrameSource, @unchecked Sendable {
    let ref: SourceRef
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let lock = NSLock()
    private var output: AVPlayerItemVideoOutput?
    private var frame: CVPixelBuffer?
    private var frameCount = 0, windowStart = CACurrentMediaTime(), fps = 0.0
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "video.source", qos: .userInteractive)

    init(ref: SourceRef, file: URL) {
        self.ref = ref
        player.isMuted = true
        let item = AVPlayerItem(url: file)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true])
        out.suppressesPlayerRendering = true
        output = out
        looper = AVPlayerLooper(player: player, templateItem: item)
        // AVPlayerLooper copies the template item: attach the output to every queued item as they come up.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.25)
        t.setEventHandler { [weak self] in self?.attach() }
        t.resume(); timer = t
        player.play()
    }

    private func attach() {
        guard !isStopped, let out = output else { return }
        for it in player.items() where !it.outputs.contains(where: { $0 === out }) { it.add(out) }
        if player.timeControlStatus == .paused { player.play() }
    }

    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    var decodedFPS: Double { lock.lock(); defer { lock.unlock() }; return fps }

    func latestFrame() -> CVPixelBuffer? {
        lock.lock(); let out = output; lock.unlock()
        if let out {
            let t = out.itemTime(forHostTime: CACurrentMediaTime())
            if out.hasNewPixelBuffer(forItemTime: t), let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
                let now = CACurrentMediaTime()
                lock.lock(); frame = pb; frameCount += 1
                if now - windowStart >= 1 { fps = Double(frameCount) / (now - windowStart); frameCount = 0; windowStart = now }
                lock.unlock()
                return pb
            }
        }
        lock.lock(); defer { lock.unlock() }; return frame
    }

    func stop() {
        lock.lock(); let was = stopped; stopped = true; lock.unlock()
        guard !was else { return }
        timer?.cancel(); timer = nil
        player.pause(); looper?.disableLooping(); player.removeAllItems()
        lock.lock(); frame = nil; output = nil; lock.unlock()
    }
    deinit { stop() }
}
