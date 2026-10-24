import Foundation
import Security

/// One generic-password item per Instagram account (service `ferry`, account `instagram:<id>`): its session cookies,
/// the only place they're kept (decision C3), and the account's profile so the app can list it before it connects.
/// This device only, after the first unlock.
nonisolated enum Keychain {
    struct Account: Codable, Equatable, Sendable {
        var cookies: [String: String]
        var viewer: IG.Viewer?
    }

    private static let service = "ferry"
    private static let prefix = "instagram:"

    static func save(_ account: Account, id: String) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        delete(id)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: prefix + id, kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Every stored account by ID.
    static func accounts() -> [String: Account] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnAttributes as String: true, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [:] }
        var accounts: [String: Account] = [:]
        for item in items {
            guard let name = item[kSecAttrAccount as String] as? String, name.hasPrefix(prefix), let data = item[kSecValueData as String] as? Data,
                  let account = try? JSONDecoder().decode(Account.self, from: data) else { continue }
            accounts[String(name.dropFirst(prefix.count))] = account
        }
        return accounts
    }

    /// The phone's web push state (docs/PLAN-push.md): Mozilla's ID for it, and each account's channel and keys as the
    /// engine made them. It holds private keys, so it's kept here and nowhere else, never logged. After the first
    /// unlock, so a background wake on a locked phone reads it.
    static func pushState() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: pushAccount, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Updated in place, never deleted first: a failed add would lose the keys, and every account would register anew.
    static func savePushState(_ state: String) {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: pushAccount]
        let data = [kSecValueData as String: Data(state.utf8)]
        if SecItemUpdate(item as CFDictionary, data as CFDictionary) == errSecItemNotFound {
            var add = item.merging(data) { $1 }
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Not an `instagram:` item, so `accounts()` skips it.
    private static let pushAccount = "push"

    static func delete(_ id: String) {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: prefix + id]
        SecItemDelete(item as CFDictionary)
    }
}
