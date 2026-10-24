// Auto capture: wire format for POST /api/studio-link/matches/{matchId}/screenshots (multipart) and the answers it gets.
import Foundation

/// Optional `kind` field. The studio no longer sends it (the server classifies every frame: lobby / results / in-game); the old
/// kinds stay supported for compatibility, and AUTO is the explicit "server decides".
enum CaptureKind: String, Codable, Sendable, CaseIterable { case liveStatus = "LIVE_STATUS", results = "RESULTS", slotList = "SLOT_LIST", auto = "AUTO" }

/// `trigger` field: scheduled frame or the operator's "Send screenshot".
enum CaptureTrigger: String, Codable, Sendable { case auto, manual }

/// `hint` field: what the OPERATOR says the screen shows (a training label only; the server still classifies).
enum CaptureHint: String, Codable, Sendable, CaseIterable, Identifiable {
    case lobby, results, inGame = "in_game"
    var id: String { rawValue }
    var title: String { switch self { case .lobby: "Lobby"; case .results: "Results"; case .inGame: "In-game" } }
}

/// One still sent to the linked match.
struct CaptureUpload: Equatable, Sendable {
    var matchId: String
    /// nil = field omitted (the server classifies the frame)
    var kind: CaptureKind?
    var jpeg: Data
    var captureId: String
    var capturedAt: Date
    var sequence: Int
    var sessionId: String
    var sceneId: String
    var sceneName: String
    var width: Int
    var height: Int
    var trigger: CaptureTrigger? = nil
    var hint: CaptureHint? = nil

    static let filename = "capture.jpg"
    /// ISO8601 UTC with milliseconds: 2026-10-23T14:05:12.123Z
    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
    /// Text fields in the order they are written (before the file part, so streaming parsers see them first).
    var fields: [(String, String)] {
        var f: [(String, String)] = kind.map { [("kind", $0.rawValue)] } ?? []
        f += [("captureId", captureId), ("capturedAt", Self.iso(capturedAt)), ("sequence", String(sequence)),
              ("sessionId", sessionId), ("sceneId", sceneId), ("sceneName", sceneName), ("width", String(width)), ("height", String(height))]
        if let trigger { f.append(("trigger", trigger.rawValue)) }
        if let hint { f.append(("hint", hint.rawValue)) }
        return f
    }
    static func == (a: CaptureUpload, b: CaptureUpload) -> Bool {
        a.matchId == b.matchId && a.kind == b.kind && a.jpeg == b.jpeg && a.captureId == b.captureId && a.capturedAt == b.capturedAt
            && a.sequence == b.sequence && a.sessionId == b.sessionId && a.sceneId == b.sceneId && a.sceneName == b.sceneName && a.width == b.width && a.height == b.height
            && a.trigger == b.trigger && a.hint == b.hint
    }
}

/// multipart/form-data encoder (RFC 7578).
enum CaptureMultipart {
    static func boundary() -> String { "----7xen-studio-\(UUID().uuidString)" }
    static func contentType(_ boundary: String) -> String { "multipart/form-data; boundary=\(boundary)" }
    /// Field names / filenames are ours (ASCII); values may be any UTF-8 (scene names). Quotes and CR/LF in names are escaped.
    static func body(boundary: String, fields: [(String, String)], fileField: String, filename: String, fileType: String, file: Data) -> Data {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "%0D").replacingOccurrences(of: "\n", with: "%0A") }
        var d = Data()
        func w(_ s: String) { d.append(Data(s.utf8)) }
        for (k, v) in fields {
            w("--\(boundary)\r\n")
            w("Content-Disposition: form-data; name=\"\(esc(k))\"\r\n\r\n")
            w(v); w("\r\n")
        }
        w("--\(boundary)\r\n")
        w("Content-Disposition: form-data; name=\"\(esc(fileField))\"; filename=\"\(esc(filename))\"\r\n")
        w("Content-Type: \(fileType)\r\n\r\n")
        d.append(file); w("\r\n")
        w("--\(boundary)--\r\n")
        return d
    }
}

/// What AirBattleground answered, already classified. Uploads never throw: transport failures are `.unreachable`.
enum CaptureReply: Equatable, Sendable {
    /// 202 {captureId, accepted, queuePosition, nextIntervalSeconds}, or the legacy 200 {count}
    case accepted(captureId: String?, queuePosition: Int?, nextIntervalSeconds: Double?)
    /// 200 for a captureId the server already has ({accepted:false, duplicate:true})
    case duplicate(nextIntervalSeconds: Double?)
    /// {accepted:false, reason:"busy"}: the previous frame is still being read; carry on
    case busy(nextIntervalSeconds: Double?)
    case badRequest(String)             // 400
    case keyRejected                    // 401 / 403
    case matchNotFound(String?)         // 404
    /// 409: match published (or locked for anything but lobby frames). The server's message.
    case conflict(String?)
    case tooLarge                       // 413
    case rateLimited(retryAfter: Double?) // 429
    case serverError(Int, String?)      // 5xx and anything else unexpected
    case unreachable                    // timeout / no network

    /// Classify an HTTP answer. `retryAfter` is the raw Retry-After header (seconds or an HTTP date).
    static func from(status: Int, body: Data, retryAfter: String? = nil, now: Date = Date()) -> CaptureReply {
        struct OK: Decodable {
            var captureId: String?; var accepted: Bool?; var queuePosition: Int?; var nextIntervalSeconds: Double?
            var count: Int?; var duplicate: Bool?; var reason: String?
        }
        let message = StudioLinkClient.errorMessage(body)
        let ok = try? JSONDecoder().decode(OK.self, from: body)
        let busy = ok?.accepted == false && ok?.reason?.lowercased() == "busy"
        switch status {
        case 202:
            if busy { return .busy(nextIntervalSeconds: ok?.nextIntervalSeconds) }
            if ok?.accepted == false && ok?.duplicate == true { return .duplicate(nextIntervalSeconds: ok?.nextIntervalSeconds) }
            return .accepted(captureId: ok?.captureId, queuePosition: ok?.queuePosition, nextIntervalSeconds: ok?.nextIntervalSeconds)
        case 200, 201:
            if busy { return .busy(nextIntervalSeconds: ok?.nextIntervalSeconds) }
            if ok?.count != nil && ok?.captureId == nil { return .accepted(captureId: nil, queuePosition: nil, nextIntervalSeconds: ok?.nextIntervalSeconds) }  // legacy {count}
            if ok?.duplicate == true || ok?.accepted == false || status == 200 { return .duplicate(nextIntervalSeconds: ok?.nextIntervalSeconds) }
            return .accepted(captureId: ok?.captureId, queuePosition: ok?.queuePosition, nextIntervalSeconds: ok?.nextIntervalSeconds)
        case 204: return .accepted(captureId: nil, queuePosition: nil, nextIntervalSeconds: nil)
        case 400: return .badRequest(message ?? "AirBattleground rejected the capture.")
        case 401, 403: return .keyRejected
        case 404: return .matchNotFound(message)
        case 409: return .conflict(message)
        case 413: return .tooLarge
        case 429: return .rateLimited(retryAfter: parseRetryAfter(retryAfter, now: now))
        default: return .serverError(status, message)
        }
    }
    static func parseRetryAfter(_ s: String?, now: Date = Date()) -> Double? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let n = Double(s) { return max(0, n) }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s).map { max(0, $0.timeIntervalSince(now)) }
    }
}

extension StudioLinkClient {
    func capturePath(_ matchId: String) -> String { "/api/studio-link/matches/\(Self.encodeComponent(matchId))/screenshots" }

    /// Multipart request: files (image/jpeg, capture.jpg) + [kind], captureId, capturedAt, sequence, sessionId, sceneId, sceneName, width, height.
    func captureRequest(_ u: CaptureUpload, boundary: String = CaptureMultipart.boundary()) throws -> URLRequest {
        var r = try request("POST", capturePath(u.matchId))
        r.setValue(CaptureMultipart.contentType(boundary), forHTTPHeaderField: "Content-Type")
        r.httpBody = CaptureMultipart.body(boundary: boundary, fields: u.fields, fileField: "files", filename: CaptureUpload.filename, fileType: "image/jpeg", file: u.jpeg)
        return r
    }

    /// POST the capture. Never throws: every outcome is a `CaptureReply` (10 s timeout, no redirects -> `.unreachable` / status).
    func uploadCapture(_ u: CaptureUpload) async -> CaptureReply {
        guard let req = try? captureRequest(u) else { Self.logCapture(u, status: nil, ms: 0, detail: "bad request url"); return .unreachable }
        let t0 = Date()
        do {
            let (data, resp) = try await session.data(for: req, delegate: CaptureNoRedirect())
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            guard let http = resp as? HTTPURLResponse else { Self.logCapture(u, status: nil, ms: ms, detail: "no HTTP response"); return .unreachable }
            let reply = CaptureReply.from(status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            Self.logCapture(u, status: http.statusCode, ms: ms, detail: "\(reply) body=\(String(decoding: data.prefix(300), as: UTF8.self))")
            return reply
        } catch {
            Self.logCapture(u, status: nil, ms: Int(Date().timeIntervalSince(t0) * 1000), detail: "transport error: \(error.localizedDescription)")
            return .unreachable
        }
    }

    /// One line per upload in the app log (Console.app / `log stream --process Studio`). Never logs the studio key.
    static func logCapture(_ u: CaptureUpload, status: Int?, ms: Int, detail: String) {
        let line = "AutoCapture: POST /api/studio-link/matches/\(encodeComponent(u.matchId))/screenshots kind=\(u.kind?.rawValue ?? "-") trigger=\(u.trigger?.rawValue ?? "-") hint=\(u.hint?.rawValue ?? "-") captureId=\(u.captureId) "
            + "seq=\(u.sequence) bytes=\(u.jpeg.count) \(u.width)x\(u.height) scene=\"\(u.sceneName)\" -> status=\(status.map(String.init) ?? "none") latency=\(ms)ms \(detail)"
        NSLog("%@", line)
    }
}

private final class CaptureNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
