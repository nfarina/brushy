import Foundation
import Security

/// Generic-password items in the login keychain — where an API key belongs
/// (never `UserDefaults`, which is a plist on disk).
enum Keychain {
    static let service = "com.dezzy.app"

    static func string(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String?, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

extension Notification.Name {
    static let apiKeysDidChange = Notification.Name("DezzyAPIKeysDidChange")
}

/// The keys the AI features use. Keychain first; the `GEMINI_API_KEY`
/// environment variable is honoured as a development convenience (Xcode
/// scheme environment, or a shell launch).
enum APIKeys {
    /// Posted on the main thread after a key is stored or cleared, so the
    /// sidebar's "add a key" hint can go away while Settings is still open.
    static var didChange: Notification.Name { .apiKeysDidChange }

    static let geminiAccount = "gemini-api-key"

    static var gemini: String? {
        get {
            if let key = Keychain.string(account: geminiAccount), !key.isEmpty { return key }
            if let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty { return key }
            return nil
        }
        set {
            Keychain.set(newValue, account: geminiAccount)
            NotificationCenter.default.post(name: .apiKeysDidChange, object: nil)
        }
    }

    static var geminiIsStoredInKeychain: Bool {
        !(Keychain.string(account: geminiAccount) ?? "").isEmpty
    }
}
