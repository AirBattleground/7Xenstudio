// Boundaries between modules. Each module owns its folder; change THIS file only for additive needs.
import Foundation
import CoreVideo
import CoreMedia

let studioWidth = 1920
let studioHeight = 1080
let defaultFPS = 60
let defaultVideoKbps = 12_000

/// What a scene slot shows. Mirrors src/shared/types.ts SourceRef.
enum SourceRef: Codable, Hashable {
    case device(id: String), camera, prop(id: String), slate, image(id: String), web(url: String)
}
enum LayoutKind: String, Codable, CaseIterable { case full, side, pip, desk, trio }
struct Scene: Codable, Identifiable, Hashable {
    var id: String; var name: String; var layout: LayoutKind; var slots: [SourceRef?]
}
struct Overlays: Codable, Hashable {
    var liveBug = false, lowerThird = false, ticker = false
    var lowerTitle = "", lowerSubtitle = "", tickerText = ""
    var logo = LogoOverlay()
    var web = WebOverlay()
}
enum OverlayCorner: String, Codable, CaseIterable, Hashable { case tl, tr, bl, br }
/// Image prop pinned to a corner. `size` is the max width in 1280x720 design units (height max is size * 5/9).
struct LogoOverlay: Codable, Hashable {
    var on = false
    var propId: String? = nil
    var corner = OverlayCorner.tr
    var size = 180.0
    var opacity = 1.0
}
/// Image (prop or URL polled every 2 s, e.g. a scoreboard PNG) fitted into a rect given as 0...1 fractions of the frame.
struct WebOverlay: Codable, Hashable {
    var on = false
    var url = ""
    var propId: String? = nil
    var x = 0.0, y = 0.0, w = 1.0, h = 1.0
    var opacity = 1.0
}
// Additive decoding: missing keys keep defaults so older stores still load.
extension LogoOverlay {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        on = (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? on
        propId = (try? c.decodeIfPresent(String.self, forKey: .propId)) ?? nil
        corner = (try? c.decodeIfPresent(OverlayCorner.self, forKey: .corner)) ?? corner
        size = (try? c.decodeIfPresent(Double.self, forKey: .size)) ?? size
        opacity = (try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? opacity
    }
}
extension WebOverlay {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        on = (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? on
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? url
        propId = (try? c.decodeIfPresent(String.self, forKey: .propId)) ?? nil
        x = (try? c.decodeIfPresent(Double.self, forKey: .x)) ?? x
        y = (try? c.decodeIfPresent(Double.self, forKey: .y)) ?? y
        w = (try? c.decodeIfPresent(Double.self, forKey: .w)) ?? w
        h = (try? c.decodeIfPresent(Double.self, forKey: .h)) ?? h
        opacity = (try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? opacity
    }
}
extension Overlays {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func b(_ k: CodingKeys) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? false }
        func s(_ k: CodingKeys) -> String { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil) ?? "" }
        liveBug = b(.liveBug); lowerThird = b(.lowerThird); ticker = b(.ticker)
        lowerTitle = s(.lowerTitle); lowerSubtitle = s(.lowerSubtitle); tickerText = s(.tickerText)
        logo = ((try? c.decodeIfPresent(LogoOverlay.self, forKey: .logo)) ?? nil) ?? LogoOverlay()
        web = ((try? c.decodeIfPresent(WebOverlay.self, forKey: .web)) ?? nil) ?? WebOverlay()
    }
}
struct Destination: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case youtube, facebook, custom }
    var id: String; var name: String; var kind: Kind; var url: String; var key: String
}

/// Produces the newest decoded frame for a source (phone HLS, webcam, image...). Thread-safe, non-blocking.
protocol FrameSource: AnyObject {
    var ref: SourceRef { get }
    func latestFrame() -> CVPixelBuffer?
    func stop()
}

/// Ingest module -> Engine: resolves a SourceRef to a live FrameSource.
protocol SourceProvider: AnyObject {
    func source(for ref: SourceRef) -> FrameSource?
}

/// Engine -> Output: one finished 1080p frame (BGRA or NV12) at a presentation time.
protocol VideoSink: AnyObject {
    func submit(video: CVPixelBuffer, pts: CMTime)
    func submit(audio: CMSampleBuffer)
}

struct OutputConfig {
    var fps = defaultFPS
    var videoKbps = defaultVideoKbps
    var recordingURL: URL?
    var destinations: [Destination] = []
    var ffmpegPath: String
    /// additive (Output): local-file-only HEVC recording; optional local preview URL (udp://, rtmp://)
    var recordHEVC = false
    var previewURL: String?
}
struct OutputStats {
    var encodeFPS = 0.0, kbps = 0.0, droppedFrames = 0, error: String?
    /// additive (Output): destination name -> last failure; VT encode latency (ms); ffmpeg restarts
    var destinationErrors: [String: String] = [:]
    var encodeLatencyMs = 0.0, restarts = 0
}

protocol OutputPipelineProtocol: VideoSink {
    func start(_ config: OutputConfig) throws
    func stop() async
    var stats: OutputStats { get }
}
