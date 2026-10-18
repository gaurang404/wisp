import Foundation
import Security

/// All Wisp secrets (secret environment values + OAuth tokens) live in ONE generic-password Keychain item,
/// so an ad-hoc–signed rebuild asks for Keychain access at most once.
struct SecretBlob: Codable, Equatable {
    var values: [String: String] = [:]          // KeyValue.id → value
    var tokens: [String: OAuthToken] = [:]      // OAuthConfig.cacheKey → token
}

enum Secrets {
    static let service = "build.wisp.app"
    static let account = "secrets"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    enum ReadResult { case found(SecretBlob), notFound, failed }

    /// `.failed` (denied, locked, undecodable) must never be treated like "empty" — writing then would wipe secrets.
    static func read() -> ReadResult {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess, let data = out as? Data,
              let blob = try? JSONDecoder().decode(SecretBlob.self, from: data) else { return .failed }
        return .found(blob)
    }

    /// Returns false when the Keychain refused the write (caller keeps a fallback).
    @discardableResult
    static func save(_ blob: SecretBlob) -> Bool {
        guard let data = try? JSONEncoder().encode(blob) else { return false }
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Wisp secrets"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
