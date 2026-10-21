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
        do {
            let (data, resp) = try await session.data(for: req, delegate: NoRedirect())
            guard let http = resp as? HTTPURLResponse else { throw ABGError.badResponse }
            return (data, http.statusCode)
        } catch let e as ABGError { throw e } catch { throw ABGError.unreachable }
    }

    private func check(_ data: Data, _ status: Int) throws {
        if status == 401 || status == 403 { throw ABGError.keyInvalid }
        guard (200..<300).contains(status) else {
            struct Err: Decodable { struct E: Decodable { var message: String? }; var error: E? }
            if let m = (try? JSONDecoder().decode(Err.self, from: data))?.error?.message, !m.isEmpty { throw ABGError.api(m) }
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
    // screenshots (matches/:id/screenshots, multipart) existed in the old client but the native app has no capture UI: not ported.
}

private struct AnyEncodable: Encodable {
    let v: any Encodable
    init(_ v: any Encodable) { self.v = v }
    func encode(to e: Encoder) throws { try v.encode(to: e) }
}
