import Foundation
import Security

/// Small generic-password store for sign-in tokens. AfterFirstUnlock so a locked phone in the
/// car (the usual CarPlay state) can still read them; ThisDeviceOnly keeps them out of backups.
enum Keychain {
    static func data(_ service: String) -> Data? {
        var out: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true]
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    /// nil deletes.
    static func set(_ data: Data?, _ service: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
