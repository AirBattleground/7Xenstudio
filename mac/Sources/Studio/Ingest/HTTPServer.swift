import Foundation
import Network

struct HTTPRequest {
    var method: String
    var path: String
    var query: String = ""
    var headers: [String: String] = [:]   // lowercased names
    var body = Data()
    var remoteIP = ""
    func header(_ n: String) -> String? { headers[n.lowercased()] }
}
struct HTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
    static func json(_ status: Int, _ obj: Any) -> HTTPResponse {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"], body: d)
    }
    static func empty(_ status: Int) -> HTTPResponse { HTTPResponse(status: status) }
}

/// Fixed-window limiter per key.
final class RateLimiter: @unchecked Sendable {
    private var hits: [String: (start: Date, count: Int)] = [:]
    private let limit: Int, window: TimeInterval, now: () -> Date
    private let lock = NSLock()
    init(limit: Int, window: TimeInterval, now: @escaping () -> Date = Date.init) { self.limit = limit; self.window = window; self.now = now }
    func allow(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        if hits.count > 10_000 { hits.removeAll() }
        if let h = hits[key], t.timeIntervalSince(h.start) < window { hits[key] = (h.start, h.count + 1); return h.count + 1 <= limit }
        hits[key] = (t, 1); return true
    }
}

/// Phone-facing routes: /api/device/* and the MediaMTX auth hook.
final class StudioRouter: @unchecked Sendable {
    let store: StudioStore, devices: DeviceManager, tokens: Tokens
    let limiter = RateLimiter(limit: 240, window: 60)
    static let maxSnapshotBytes = 10 * 1024 * 1024

    init(store: StudioStore, devices: DeviceManager, tokens: Tokens) { self.store = store; self.devices = devices; self.tokens = tokens }

    func handle(_ req: HTTPRequest) async -> HTTPResponse {
        do { return try await route(req) } catch let e as APIError {
            var err: [String: Any] = ["code": e.code, "message": e.message]
            if let f = e.fields { err["fields"] = f }
            return .json(e.status, ["error": err])
        } catch {
            return .json(500, ["error": ["code": "INTERNAL", "message": "Something went wrong in the studio. Try again."]])
        }
    }

    private func route(_ req: HTTPRequest) async throws -> HTTPResponse {
        if req.path.hasPrefix("/api/device/") {
            var sub = String(req.path.dropFirst("/api/device/".count))
            while sub.hasSuffix("/") { sub.removeLast() }
            return try await deviceApi(req, sub)
        }
        if req.path == "/internal/media/auth" {
            guard req.method == "POST", isLoopback(req.remoteIP) else { throw APIError.notFound() }
            let body = (try? JSONDecoder().decode(MediaAuthRequest.self, from: req.body)) ?? MediaAuthRequest()
            let ok = authorizeMedia(body, tokens: tokens, deviceKeyHash: { [store] in store.device($0)?.keyHash })
            return .empty(ok ? 200 : 401)
        }
        throw APIError.notFound()
    }

    private func jsonBody(_ req: HTTPRequest) throws -> [String: Any] {
        if req.body.isEmpty { return [:] }
        guard let o = try? JSONSerialization.jsonObject(with: req.body) else { throw APIError.bad("The request body isn't valid JSON") }
        guard let d = o as? [String: Any] else { throw APIError.bad("Please check your input: Expected object", ["_": "Expected object"]) }
        return d
    }

    private func deviceApi(_ req: HTTPRequest, _ sub: String) async throws -> HTTPResponse {
        guard req.method == "POST" else { throw APIError.notFound() }
        guard limiter.allow(req.remoteIP) else { throw APIError(status: 429, code: "RATE_LIMITED", message: "Too many requests from this device. Wait a minute and try again.") }
        let dev = try devices.fromKey(req.header("x-device-key"))
        if sub.hasPrefix("snapshots/") {
            let rid = String(sub.dropFirst("snapshots/".count))
            guard !rid.isEmpty, rid.count <= 80, rid.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { throw APIError.notFound() }
            var img: Data? = req.body
            let ct = req.header("content-type") ?? ""
            if ct.lowercased().hasPrefix("multipart/form-data") {
                img = Multipart.parts(req.body, contentType: ct).first { $0.name == "image" || $0.name == "file" }?.data
            }
            guard let img, !img.isEmpty else { throw APIError.bad("Send the screenshot as the 'image' field", ["image": "Required"]) }
            guard imageType(img) != nil else { throw APIError.bad("Only PNG, JPEG or WebP images", ["image": "Only PNG, JPEG or WebP images"]) }
            guard devices.fulfilSnapshot(deviceId: dev.id, requestId: rid, png: img) else { throw APIError.notFound("That capture request has expired") }
            return .empty(204)
        }
        let body = try jsonBody(req)
        switch sub {
        case "hello":
            func s(_ k: String, _ max: Int) throws -> String? {
                guard let v = body[k] else { return nil }
                guard let str = v as? String else { throw APIError.bad("Please check your input: Expected string", [k: "Expected string"]) }
                let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
                guard t.count <= max else { throw APIError.bad("Please check your input: Too long", [k: "Too long"]) }
                return t
            }
            return .json(200, devices.hello(dev, model: try s("deviceModel", 80), osVersion: try s("osVersion", 40), appVersion: try s("appVersion", 40)))
        case "heartbeat":
            try validateHeartbeat(body)
            return .json(200, devices.heartbeat(dev, body))
        case "stream/start":
            if let q = body["quality"], !["480p", "720p", "1080p"].contains(q as? String ?? "") { throw APIError.bad("Please check your input: Invalid option", ["quality": "Invalid option"]) }
            if let f = body["fps"], !(f is NSNumber && [30.0, 60.0].contains((f as! NSNumber).doubleValue)) { throw APIError.bad("Please check your input: Invalid input", ["fps": "Invalid input"]) }
            return .json(200, devices.streamStart(dev))
        case "stream/stop":
            devices.streamStop(dev); return .empty(204)
        default: throw APIError.notFound()
        }
    }

    private func validateHeartbeat(_ b: [String: Any]) throws {
        var fields: [String: String] = [:]
        func num(_ k: String, _ lo: Double, _ hi: Double, int: Bool = false) {
            guard let v = b[k] else { return }
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { fields[k] = "Expected number"; return }
            let d = n.doubleValue
            if d < lo { fields[k] = "Too small" } else if d > hi { fields[k] = "Too big" } else if int && d != d.rounded() { fields[k] = "Expected integer" }
        }
        func en(_ k: String, _ opts: [String]) { if let v = b[k], !opts.contains(v as? String ?? "") { fields[k] = "Invalid option" } }
        func bool(_ k: String) { if let v = b[k], !(v is Bool) { fields[k] = "Expected boolean" } }
        en("state", ["IDLE", "LIVE"]); en("thermal", ["nominal", "fair", "serious", "critical"]); en("network", ["wifi", "cellular"])
        if let q = b["quality"], (q as? String).map({ $0.count > 10 }) ?? true { fields["quality"] = "Invalid" }
        bool("autoDowngraded"); bool("charging")
        num("battery", 0, 1); num("cpuPct", 0, 10_000); num("memMB", 0, 100_000); num("fps", 0, 240)
        num("bitrateKbps", 0, 1_000_000); num("width", 0, 10_000, int: true); num("height", 0, 10_000, int: true)
        if let (k, v) = fields.sorted(by: { $0.key < $1.key }).first {
            throw APIError.bad(fields.count == 1 ? "Please check your input: \(v)" : "Please check the highlighted fields", fields).with(k)
        }
    }
}
private extension APIError { func with(_ k: String) -> APIError { self } }

func imageType(_ b: Data) -> String? {
    let a = [UInt8](b.prefix(12)); guard a.count >= 12 else { return nil }
    if a[0] == 0x89 && a[1] == 0x50 && a[2] == 0x4E && a[3] == 0x47 { return "image/png" }
    if a[0] == 0xff && a[1] == 0xd8 && a[2] == 0xff { return "image/jpeg" }
    if a[0..<4] == [0x52, 0x49, 0x46, 0x46] && a[8..<12] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
    if a[0..<4] == [0x47, 0x49, 0x46, 0x38] { return "image/gif" }
    return nil
}

enum Multipart {
    struct Part { var name: String; var filename: String?; var data: Data }
    static func parts(_ body: Data, contentType: String) -> [Part] {
        guard let r = contentType.range(of: "boundary=") else { return [] }
        var boundary = String(contentType[r.upperBound...]).split(separator: ";").first.map(String.init) ?? ""
        boundary = boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard !boundary.isEmpty else { return [] }
        let delim = Data("--\(boundary)".utf8), crlf2 = Data("\r\n\r\n".utf8)
        var out: [Part] = []
        var pos = body.range(of: delim)
        while let p = pos {
            let start = p.upperBound
            if body.count >= start + 2, body[start] == 0x2d, body[start + 1] == 0x2d { break }
            guard let he = body.range(of: crlf2, in: start..<body.count),
                  let next = body.range(of: delim, in: he.upperBound..<body.count) else { break }
            let head = String(decoding: body[start..<he.lowerBound], as: UTF8.self)
            func attr(_ n: String) -> String? {
                guard let r = head.range(of: "\(n)=\"") else { return nil }
                return head[r.upperBound...].prefix { $0 != "\"" }.description
            }
            if let name = attr("name") {
                let end = max(he.upperBound, next.lowerBound - 2)
                out.append(Part(name: name, filename: attr("filename"), data: body.subdata(in: he.upperBound..<end)))
            }
            pos = next
        }
        return out
    }
}

/// Minimal HTTP/1.1 server on Network.framework (Connection: close per request).
final class HTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "studio.http")
    let port: UInt16
    let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    static let maxBody = 12 * 1024 * 1024
    var onError: ((Error) -> Void)?

    init(port: UInt16 = 4400, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) { self.port = port; self.handler = handler }

    func start() throws {
        let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] s in if case .failed(let e) = s { self?.onError?(e) } }
        l.start(queue: queue)
        listener = l
    }
    func stop() { listener?.cancel(); listener = nil }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        var ip = ""
        if case .hostPort(let host, _) = c.endpoint {
            switch host {
            case .ipv4(let a): ip = "\(a)"
            case .ipv6(let a): ip = "\(a)"
            default: ip = "\(host)"
            }
            if let i = ip.firstIndex(of: "%") { ip = String(ip[..<i]) }
        }
        read(c, Data(), ip)
        queue.asyncAfter(deadline: .now() + 60) { c.cancel() }
    }

    private func read(_ c: NWConnection, _ acc: Data, _ ip: String) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = acc; if let data { buf.append(data) }
            switch Self.parse(buf, ip: ip) {
            case .complete(let req):
                Task {
                    let r = await self.handler(req)
                    self.send(c, r)
                }
            case .tooBig: self.send(c, .json(413, ["error": ["code": "VALIDATION_ERROR", "message": "That upload is too big"]]))
            case .bad: self.send(c, .json(400, ["error": ["code": "VALIDATION_ERROR", "message": "Bad request"]]))
            case .needMore:
                if err != nil || done { c.cancel() } else { self.read(c, buf, ip) }
            }
        }
    }

    enum Parsed { case complete(HTTPRequest), needMore, bad, tooBig }
    static func parse(_ buf: Data, ip: String) -> Parsed {
        guard let he = buf.range(of: Data("\r\n\r\n".utf8)) else { return buf.count > 32 * 1024 ? .bad : .needMore }
        let head = String(decoding: buf[..<he.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return .bad }
        var headers: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        if len < 0 || len > maxBody { return .tooBig }
        guard buf.count - he.upperBound >= len else { return .needMore }
        let target = String(first[1])
        let q = target.firstIndex(of: "?")
        let rawPath = q.map { String(target[..<$0]) } ?? target
        return .complete(HTTPRequest(method: String(first[0]).uppercased(), path: rawPath.removingPercentEncoding ?? rawPath,
                                     query: q.map { String(target[target.index(after: $0)...]) } ?? "", headers: headers,
                                     body: buf.subdata(in: he.upperBound..<(he.upperBound + len)), remoteIP: ip))
    }

    private func send(_ c: NWConnection, _ r: HTTPResponse) {
        var h = r.headers
        h["Content-Length"] = String(r.body.count); h["Connection"] = "close"
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 413: "Payload Too Large", 429: "Too Many Requests"][r.status] ?? "Error"
        var out = Data("HTTP/1.1 \(r.status) \(reason)\r\n".utf8)
        for (k, v) in h { out.append(Data("\(k): \(v)\r\n".utf8)) }
        out.append(Data("\r\n".utf8)); out.append(r.body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
