import Foundation
import Security

/// The device token is a bearer credential for the whole computer, so it lives
/// in the login keychain rather than next to the saved machines.
enum Keychain {
    private static let service = "com.openmausbot.mac.device-token"

    static func token(for computerId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: computerId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setToken(_ token: String, for computerId: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: computerId,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        if status != errSecSuccess {
            Log.error("keychain write failed (\(status)) for \(computerId)")
        }
        return status == errSecSuccess
    }

    static func removeToken(for computerId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: computerId,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum Log {
    static func info(_ message: String) {
        #if DEBUG
        FileHandle.standardError.write(Data("[MausBot] \(message)\n".utf8))
        #endif
    }

    static func error(_ message: String) {
        FileHandle.standardError.write(Data("[MausBot] \(message)\n".utf8))
    }
}
