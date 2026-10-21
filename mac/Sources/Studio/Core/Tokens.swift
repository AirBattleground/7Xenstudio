import Foundation
import CryptoKit

let publishTokenTTL: TimeInterval = 600
let internalUser = "studio"
let deviceKeyPrefix = "7xk_"

func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}
func base64URL(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
func safeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var r: UInt8 = 0
    for i in 0..<x.count { r |= x[i] ^ y[i] }
    return r == 0
}
func randomBase64URL(bytes: Int) -> String {
    var b = [UInt8](repeating: 0, count: bytes)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
    return base64URL(Data(b))
}
func randomHex(bytes: Int) -> String {
    var b = [UInt8](repeating: 0, count: bytes)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
    return b.map { String(format: "%02x", $0) }.joined()
}
/// 24 lowercase alphanumerics (prefix + 23 hex): fits MediaMTX's live/dev_<id> path pattern.
func newId(_ prefix: String = "s") -> String { prefix + String(randomHex(bytes: 12).prefix(23)) }
func newDeviceKey() -> String { deviceKeyPrefix + randomBase64URL(bytes: 24) }

/// Everything signed with the studio secret: phone publish tokens (10 min) and the internal MediaMTX credentials.
final class Tokens {
    let internalPass: String
    private let publishKey: SymmetricKey

    init(secret: Data) {
        func derive(_ p: String) -> Data {
            var h = SHA256(); h.update(data: Data("7xen-studio:\(p):".utf8)); h.update(data: secret)
            return Data(h.finalize())
        }
        internalPass = String(derive("internal").map { String(format: "%02x", $0) }.joined().prefix(40))
        publishKey = SymmetricKey(data: derive("publish"))
    }

    var internalAuthHeader: String { "Basic " + Data("\(internalUser):\(internalPass)".utf8).base64EncodedString() }

    func isInternal(user: String?, password: String?) -> Bool {
        user == internalUser && !(password ?? "").isEmpty && safeEqual(password!, internalPass)
    }

    private func sign(_ id: String, _ keyHash: String, _ exp: Int64) -> String {
        base64URL(Data(HMAC<SHA256>.authenticationCode(for: Data("\(id).\(keyHash).\(exp)".utf8), using: publishKey)))
    }

    func publishToken(deviceId: String, keyHash: String, now: Date = Date()) -> (token: String, expiresAt: Date) {
        let exp = Int64(now.timeIntervalSince1970 * 1000 + publishTokenTTL * 1000)
        return ("\(exp).\(sign(deviceId, keyHash, exp))", Date(timeIntervalSince1970: Double(exp) / 1000))
    }

    func verifyPublishToken(deviceId: String, keyHash: String, token: String, now: Date = Date()) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let exp = Int64(parts[0]), !parts[1].isEmpty else { return false }
        if Double(exp) < now.timeIntervalSince1970 * 1000 { return false }
        return safeEqual(String(parts[1]), sign(deviceId, keyHash, exp))
    }
}

/// MediaMTX 1.x auth hook body.
struct MediaAuthRequest: Decodable {
    var user: String?, password: String?, ip: String?, action: String?, path: String?, protocolName: String?, query: String?
    enum CodingKeys: String, CodingKey { case user, password, ip, action, path, query, protocolName = "protocol" }
}

func devicePath(_ id: String) -> String { "live/dev_\(id)" }
func showPath(_ id: String) -> String { "live/show_\(id)" }

func isLoopback(_ ip: String?) -> Bool {
    guard let ip else { return false }
    return ip == "::1" || ip.hasPrefix("127.") || ip.hasPrefix("::ffff:127.")
}

private func matches(_ s: String, _ pattern: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (0..<m.numberOfRanges).map { i in
        Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
    }
}

/// May this publish / read happen? (port of media.ts authorizeMedia)
func authorizeMedia(_ req: MediaAuthRequest, tokens: Tokens, deviceKeyHash: (String) -> String?, now: Date = Date()) -> Bool {
    if tokens.isInternal(user: req.user, password: req.password) { return true }
    let local = isLoopback(req.ip)
    if req.action == "read" || req.action == "playback" { return local }
    guard req.action == "publish" else { return false }
    let path = req.path ?? ""
    if matches(path, "^live/show_[A-Za-z0-9]{8,40}$") != nil { return local }
    guard let m = matches(path, "^live/dev_([A-Za-z0-9]{8,40})$"), let keyHash = deviceKeyHash(m[1]) else { return false }
    var token = ""
    for pair in (req.query ?? "").split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1)
        if kv.count == 2, kv[0] == "token" { token = String(kv[1]).removingPercentEncoding ?? String(kv[1]) }
    }
    return tokens.verifyPublishToken(deviceId: m[1], keyHash: keyHash, token: token, now: now)
}
