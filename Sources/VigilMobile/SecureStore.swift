import Foundation
import Security

/// Keychain storage for the pairing (device id, key, host). This device only, available after
/// first unlock (so background sync works), never synced to iCloud Keychain or backups.
public enum SecureStore {
    static let service = "dev.vigil.pairing"

    public struct Pairing: Codable, Equatable {
        public var hostID: String
        public var hostName: String
        public var deviceID: String
        public var key: Data
        public var pairedAt: Date
    }

    public static func load() -> Pairing? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "host", kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    @discardableResult
    public static func save(_ p: Pairing) -> Bool {
        clear()
        guard let data = try? JSONEncoder().encode(p) else { return false }
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "host", kSecValueData as String: data,
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        #if os(iOS)
        q[kSecAttrSynchronizable as String] = false
        #endif
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    public static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
