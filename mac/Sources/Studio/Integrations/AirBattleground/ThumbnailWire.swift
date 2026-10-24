// YouTube thumbnail: image encoding and the wire format for
// POST /api/studio-link/broadcasts/{broadcastId}/thumbnail (multipart: `file`, optional `matchId`).
// The studio has no YouTube credentials: AirBattleground sets the thumbnail on the admin's broadcast.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Exactly 1280x720 (16:9) sRGB JPEG, at most 2 MB (YouTube's custom thumbnail limits).
enum ThumbnailImage {
    static let width = 1280, height = 720
    static var size: CGSize { CGSize(width: width, height: height) }
    static let maxBytes = 2 * 1024 * 1024
    /// JPEG qualities tried in order until the file fits `maxBytes`.
    static let qualities: [Double] = [0.92, 0.85, 0.78, 0.7, 0.6, 0.5, 0.4, 0.3]

    /// Any image -> 1280x720 sRGB (scaled to cover, centre-cropped when it isn't 16:9).
    static func normalized(_ img: CGImage) -> CGImage? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        c.interpolationQuality = .high
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        guard iw > 0, ih > 0 else { return nil }
        let s = max(CGFloat(width) / iw, CGFloat(height) / ih)
        let dw = iw * s, dh = ih * s
        c.draw(img, in: CGRect(x: (CGFloat(width) - dw) / 2, y: (CGFloat(height) - dh) / 2, width: dw, height: dh))
        return c.makeImage()
    }

    static func jpeg(_ img: CGImage, quality: Double) -> Data? {
        let d = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(d, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? d as Data : nil
    }

    /// Normalise, then encode with the highest quality that fits `maxBytes` (nil when even the lowest doesn't).
    static func encode(_ img: CGImage, maxBytes: Int = maxBytes) -> Data? {
        guard let n = normalized(img) else { return nil }
        for q in qualities { if let d = jpeg(n, quality: q), d.count <= maxBytes { return d } }
        return nil
    }

    /// PNG / JPEG file from disk -> upload-ready JPEG.
    static func encodeFile(_ url: URL) -> Data? { load(url).flatMap { encode($0) } }
    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
    /// Pixel size of encoded image data (tests, sanity checks).
    static func pixelSize(_ data: Data) -> (w: Int, h: Int)? { decode(data).map { ($0.width, $0.height) } }
}

/// One thumbnail for an open broadcast.
struct ThumbnailUpload: Equatable, Sendable {
    var broadcastId: String
    var matchId: String?
    var image: Data
    var contentType = "image/jpeg"
    var filename: String { contentType == "image/png" ? "thumbnail.png" : "thumbnail.jpg" }
    var fields: [(String, String)] { matchId.map { [("matchId", $0)] } ?? [] }
}

/// What AirBattleground answered, classified. Uploads never throw: transport failures are `.unreachable`.
enum ThumbnailReply: Equatable, Sendable {
    /// 200 { ok: true, url }
    case set(url: String?)
    /// 403 THUMBNAIL_NOT_ALLOWED: the channel isn't verified for custom thumbnails (server message)
    case notAllowed(String?)
    /// 401 / other 403: the studio key was refused
    case keyRejected
    case badRequest(String?)          // 400
    case notFound(String?)            // 404: broadcast unknown
    case notReady(String?)            // 409: broadcast not ready / ended
    case tooLarge                     // 413
    case rateLimited(retryAfter: Double?) // 429
    case unsupported                  // 501: the server doesn't do thumbnails (yet)
    case serverError(Int, String?)    // 5xx (except 501) and anything unexpected
    case unreachable                  // timeout / no network

    static func from(status: Int, body: Data, retryAfter: String? = nil, now: Date = Date()) -> ThumbnailReply {
        struct OK: Decodable { var ok: Bool?; var url: String? }
        struct Err: Decodable { struct E: Decodable { var code: String?; var message: String? }; var error: E? }
        let err = (try? JSONDecoder().decode(Err.self, from: body))?.error
        let message = err?.message.flatMap { $0.isEmpty ? nil : $0 }
        switch status {
        case 200..<300:
            let ok = try? JSONDecoder().decode(OK.self, from: body)
            if ok?.ok == false { return .serverError(status, message) }
            return .set(url: ok?.url)
        case 400: return .badRequest(message)
        case 401: return .keyRejected
        case 403: return err?.code == "THUMBNAIL_NOT_ALLOWED" ? .notAllowed(message) : .keyRejected
        case 404: return .notFound(message)
        case 409: return .notReady(message)
        case 413: return .tooLarge
        case 429: return .rateLimited(retryAfter: CaptureReply.parseRetryAfter(retryAfter, now: now))
        case 501: return .unsupported
        default: return .serverError(status, message)
        }
    }

    var isSuccess: Bool { if case .set = self { true } else { false } }
    /// Worth retrying by itself: 5xx (not 501) and timeouts only.
    var isRetryable: Bool {
        switch self {
        case .unreachable: true
        case .serverError(let c, _): c >= 500
        default: false
        }
    }
    /// Operator-facing sentence (amber in the UI; `.set` is the green check).
    var message: String {
        switch self {
        case .set: "Thumbnail set ✓"
        case .notAllowed(let m): m ?? "YouTube refused the custom thumbnail: the channel isn't verified for custom thumbnails."
        case .keyRejected: ABGError.keyInvalid.errorDescription ?? ""
        case .badRequest(let m): m ?? "AirBattleground rejected the thumbnail image."
        case .notFound(let m): m ?? "AirBattleground doesn't know this broadcast any more."
        case .notReady(let m): m ?? "The YouTube broadcast isn't ready (or has ended). Try again in a moment."
        case .tooLarge: "The thumbnail is too large for AirBattleground (2 MB max)."
        case .rateLimited(let s): "AirBattleground is busy. Try again" + (s.map { " in \(Int($0.rounded(.up))) s." } ?? " shortly.")
        case .unsupported: "AirBattleground doesn't support thumbnails yet"
        case .serverError(let c, let m): m.map { "AirBattleground: \($0)" } ?? "AirBattleground answered with an error (\(c))."
        case .unreachable: ABGError.unreachable.errorDescription ?? ""
        }
    }
}

extension StudioLinkClient {
    func thumbnailPath(_ broadcastId: String) -> String { "/api/studio-link/broadcasts/\(Self.encodeComponent(broadcastId))/thumbnail" }

    func thumbnailRequest(_ u: ThumbnailUpload, boundary: String = CaptureMultipart.boundary()) throws -> URLRequest {
        var r = try request("POST", thumbnailPath(u.broadcastId))
        r.timeoutInterval = 30           // a 2 MB upload on a weak uplink
        r.setValue(CaptureMultipart.contentType(boundary), forHTTPHeaderField: "Content-Type")
        r.httpBody = CaptureMultipart.body(boundary: boundary, fields: u.fields, fileField: "file", filename: u.filename, fileType: u.contentType, file: u.image)
        return r
    }

    /// POST the thumbnail. Never throws. Logs method, path, size, status and latency (never the studio key).
    func uploadThumbnail(_ u: ThumbnailUpload) async -> ThumbnailReply {
        let path = thumbnailPath(u.broadcastId)
        func log(_ status: Int?, _ ms: Int, _ detail: String) {
            NSLog("%@", "StudioLink: POST \(path) thumbnail bytes=\(u.image.count) type=\(u.contentType) matchId=\(u.matchId ?? "-") -> status=\(status.map(String.init) ?? "none") latency=\(ms)ms \(detail)")
        }
        guard let req = try? thumbnailRequest(u) else { log(nil, 0, "bad request url"); return .unreachable }
        let t0 = Date()
        do {
            let (data, resp) = try await session.data(for: req, delegate: ThumbnailNoRedirect())
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            guard let http = resp as? HTTPURLResponse else { log(nil, ms, "no HTTP response"); return .unreachable }
            let reply = ThumbnailReply.from(status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            log(http.statusCode, ms, "\(reply)")
            return reply
        } catch {
            log(nil, Int(Date().timeIntervalSince(t0) * 1000), "transport error: \(error.localizedDescription)")
            return .unreachable
        }
    }
}

private final class ThumbnailNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
