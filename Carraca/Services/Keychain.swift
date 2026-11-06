import Foundation
import Security

// MARK: - Credenciales (Llavero de iOS)

struct Credentials: Codable, Equatable {
    var server: String
    var user: String
    var pass: String
    /// true si el usuario dejó el servidor vacío (servidor Carraca, se actualiza solo desde config.json).
    /// Solo existe en la versión privada (Ad Hoc).
    var usesDefaultServer: Bool
    /// Si no es nil, la cuenta es una lista M3U (server/user/pass vacíos).
    var m3u: String? = nil
}

enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.carraca.smarter.login",
        kSecAttrAccount as String: "creds",
    ]

    static func save(_ c: Credentials) {
        guard let data = try? JSONEncoder().encode(c) else { return }
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> Credentials? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: d)
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}
