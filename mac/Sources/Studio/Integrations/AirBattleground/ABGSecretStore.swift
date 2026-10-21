import Foundation
import Security

/// Where the studio key lives. The key never goes into store.json.
protocol ABGSecretStore: Sendable {
    func load() -> ABGCredentials?
    func save(_ c: ABGCredentials) throws
    func clear()
}

struct ABGKeychainStore: ABGSecretStore {
    var service = "com.7xen.studio.airbattleground"
    var account = "studio-link"
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    func load() -> ABGCredentials? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(ABGCredentials.self, from: d)
    }
    func save(_ c: ABGCredentials) throws {
        let data = try JSONEncoder().encode(c)
        SecItemDelete(query as CFDictionary)
        var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw ServiceError(message: "Could not save the AirBattleground key in the macOS Keychain (error \(st)).") }
    }
    func clear() { SecItemDelete(query as CFDictionary) }
}

final class ABGMemorySecretStore: ABGSecretStore, @unchecked Sendable {
    private let lock = NSLock(); private var c: ABGCredentials?
    init(_ c: ABGCredentials? = nil) { self.c = c }
    func load() -> ABGCredentials? { lock.withLock { c } }
    func save(_ v: ABGCredentials) throws { lock.withLock { c = v } }
    func clear() { lock.withLock { c = nil } }
}
