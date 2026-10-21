import Foundation

/// AirBattleground connect links (port of link.ts). Accepted forms:
///   7xen-studio://connect?host=https://airbattleground.com&key=sw_...   (the QR on AirBattleground -> Manager -> Studio)
///   https://airbattleground.com/...?key=sw_...                            (host = that origin)
///   sw_...                                                                (bare key, default host)
struct ABGConnectLink: Equatable { var host: String; var key: String }

enum ABGLink {
    static func isKey(_ s: String) -> Bool {
        guard s.hasPrefix("sw_"), (11...203).contains(s.count) else { return false }   // sw_ + 8...200
        return s.dropFirst(3).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
    static func cleanHost(_ raw: String) -> String? {
        guard let u = URL(string: raw), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = u.host, !host.isEmpty else { return nil }
        var o = "\(scheme)://\(host.contains(":") ? "[\(host)]" : host)"
        if let p = u.port, !(scheme == "https" && p == 443), !(scheme == "http" && p == 80) { o += ":\(p)" }
        return o
    }
    private static func query(_ q: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let k = kv.first else { continue }
            let v = kv.count > 1 ? String(kv[1]) : ""
            out[String(k).removingPercentEncoding ?? String(k)] = (v.replacingOccurrences(of: "+", with: " ")).removingPercentEncoding ?? v
        }
        return out
    }
    static func parse(_ input: String) -> ABGConnectLink? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isKey(text) { return ABGConnectLink(host: abgDefaultHost, key: text) }
        // custom scheme read by hand (a scheme starting with a digit is not a valid URL scheme)
        if let r = text.range(of: #"^7xen-studio://connect/?\?"#, options: [.regularExpression, .caseInsensitive]) {
            let q = query(String(text[r.upperBound...]))
            let key = (q["key"] ?? "").trimmingCharacters(in: .whitespaces)
            let hostRaw = (q["host"] ?? "").trimmingCharacters(in: .whitespaces)
            guard let host = cleanHost(hostRaw.isEmpty ? abgDefaultHost : hostRaw), isKey(key) else { return nil }
            return ABGConnectLink(host: host, key: key)
        }
        if text.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil,
           let comps = URLComponents(string: text), let u = URL(string: text) {
            let items = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            let key = (items["key"] ?? "").trimmingCharacters(in: .whitespaces)
            let hostRaw = (items["host"] ?? "").trimmingCharacters(in: .whitespaces)
            guard let origin = cleanHost(u.absoluteString), let host = hostRaw.isEmpty ? origin : cleanHost(hostRaw), isKey(key) else { return nil }
            return ABGConnectLink(host: host, key: key)
        }
        return nil
    }
    /// "sw_abcd...wxyz": recognise a key without showing it.
    static func mask(_ key: String) -> String { key.count <= 10 ? key : "\(key.prefix(7))…\(key.suffix(4))" }
}
