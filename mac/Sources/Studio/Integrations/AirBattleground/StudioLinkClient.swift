import Foundation

/// AirBattleground's studio-link API (header X-Studio-Key). The key is only ever sent to `host`.
/// Port of src/server/integrations/airbattleground/client.ts: same paths, bodies, 10 s timeout, no redirects.
struct StudioLinkClient: Sendable {
    let host: String
    let key: String
    var session: URLSession = .shared
    static let timeout: TimeInterval = 10

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    /// encodeURIComponent
    static func encodeComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")) ?? s
    }

    func request(_ method: String, _ path: String, json: (any Encodable)? = nil) throws -> URLRequest {
        guard let url = URL(string: host + path) else { throw ABGError.unreachable }
        var r = URLRequest(url: url, timeoutInterval: Self.timeout)
        r.httpMethod = method
        r.setValue(key, forHTTPHeaderField: "X-Studio-Key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONEncoder().encode(AnyEncodable(json))
        }
        return r
    }

    private func perform(_ req: URLRequest) async throws -> (Data, Int) {
        let t0 = Date()
        do {
            let (data, resp) = try await session.data(for: req, delegate: NoRedirect())
            guard let http = resp as? HTTPURLResponse else { Self.log(req, status: nil, since: t0); throw ABGError.badResponse }
            Self.log(req, status: http.statusCode, since: t0)
            return (data, http.statusCode)
        } catch let e as ABGError { throw e } catch { Self.log(req, status: nil, since: t0, detail: "transport error"); throw ABGError.unreachable }
    }

    /// One line per request: method, path, status, latency (the path carries the captureId for capture results). Never the key.
    static func log(_ req: URLRequest, status: Int?, since t0: Date, detail: String = "") {
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        NSLog("%@", "StudioLink: \(req.httpMethod ?? "GET") \(req.url?.path ?? "?") -> status=\(status.map(String.init) ?? "none") latency=\(ms)ms \(detail)")
    }

    /// `error.code` of an error body ("CAPTURE_DONE", "CONFLICT", …), nil when there is none.
    static func errorCode(_ data: Data) -> String? {
        struct Err: Decodable { struct E: Decodable { var code: String? }; var error: E? }
        return (try? JSONDecoder().decode(Err.self, from: data))?.error?.code
    }
    static func errorMessage(_ data: Data) -> String? {
        struct Err: Decodable { struct E: Decodable { var message: String? }; var error: E? }
        return (try? JSONDecoder().decode(Err.self, from: data))?.error?.message.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func check(_ data: Data, _ status: Int) throws {
        if status == 401 || status == 403 { throw ABGError.keyInvalid }
        guard (200..<300).contains(status) else {
            if status == 409 { throw ABGError.conflict(Self.errorMessage(data) ?? "AirBattleground refused: the match isn't in the right state.") }
            if let m = Self.errorMessage(data) { throw ABGError.api(m) }
            throw ABGError.http(status)
        }
    }

    func call<T: Decodable>(_ method: String, _ path: String, json: (any Encodable)? = nil, as: T.Type = T.self) async throws -> T {
        let (data, status) = try await perform(try request(method, path, json: json))
        try check(data, status)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw ABGError.badResponse }
    }
    func callVoid(_ method: String, _ path: String, json: (any Encodable)? = nil) async throws {
        let (data, status) = try await perform(try request(method, path, json: json))
        try check(data, status)
    }

    struct Me: Decodable {
        struct Manager: Decodable { var name: String? }
        struct Org: Decodable { var name: String? }
        var manager: Manager?
        var org: Org?
        var account: ABGAccount { ABGAccount(name: manager?.name ?? "Manager", org: org?.name) }
    }
    func me() async throws -> Me { try await call("GET", "/api/studio-link/me") }
    func matches() async throws -> [ABGMatch] {
        struct R: Decodable { var items: [ABGMatch]? }
        return try await call("GET", "/api/studio-link/matches", as: R.self).items ?? []
    }
    func outputs() async throws -> ABGOutputs { try await call("GET", "/api/studio-link/outputs") }
    func startBroadcast(_ input: ABGBroadcastInput) async throws -> ABGBroadcast { try await call("POST", "/api/studio-link/broadcasts", json: input) }
    func heartbeat(id: String, status: ABGHeartbeat) async throws -> Bool {
        struct R: Decodable { var stop: Bool? }
        return try await call("POST", "/api/studio-link/broadcasts/\(Self.encodeComponent(id))/heartbeat", json: status, as: R.self).stop ?? false
    }
    func stopBroadcast(id: String) async throws { try await callVoid("POST", "/api/studio-link/broadcasts/\(Self.encodeComponent(id))/stop") }
    // screenshots (matches/:id/screenshots, multipart): see CaptureWire.swift (uploadCapture)

    // MARK: match control (start / stop) and capture results

    func matchPath(_ matchId: String, _ tail: String) -> String { "/api/studio-link/matches/\(Self.encodeComponent(matchId))/\(tail)" }

    /// POST …/start or …/stop: the answer is the same body as GET …/live (raw, parsed by the caller).
    /// 409 -> .conflict(server message), 404 -> .matchNotFound, 401/403 -> .keyInvalid.
    func matchAction(_ matchId: String, _ action: String) async throws -> Data {
        let (data, status) = try await perform(try request("POST", matchPath(matchId, action)))
        if status == 404 { throw ABGError.matchNotFound(Self.errorMessage(data)) }
        try check(data, status)
        return data
    }
    func startMatch(_ matchId: String) async throws -> Data { try await matchAction(matchId, "start") }
    func stopMatch(_ matchId: String) async throws -> Data { try await matchAction(matchId, "stop") }

    /// GET …/captures/{captureId}. Never throws.
    func captureResult(matchId: String, captureId: String) async -> CaptureResultReply {
        do {
            let (data, status) = try await perform(try request("GET", matchPath(matchId, "captures/\(Self.encodeComponent(captureId))")))
            if status == 404 { return .notFound }
            if status == 401 || status == 403 { return .failed(ABGError.keyInvalid.errorDescription ?? "") }
            guard (200..<300).contains(status) else { return .failed(Self.errorMessage(data) ?? "AirBattleground answered with an error (\(status)).") }
            guard let r = try? JSONDecoder().decode(CaptureResult.self, from: data) else { return .failed(ABGError.badResponse.errorDescription ?? "") }
            return .result(r)
        } catch { return .failed(ABGController.message(error)) }
    }
}

private struct AnyEncodable: Encodable {
    let v: any Encodable
    init(_ v: any Encodable) { self.v = v }
    func encode(to e: Encoder) throws { try v.encode(to: e) }
}
