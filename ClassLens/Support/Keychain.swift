import Foundation
import Security

/// Stores secrets (API keys) as generic passwords in the login keychain. Never log what passes through here.
enum Keychain {
    static let service = "com.chenshaojie.ClassLens"

    enum Failure: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status): "钥匙串操作失败（\(status)）：\(SecCopyErrorMessageString(status, nil) as String? ?? "")"
            }
        }
    }

    static func read(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    static func save(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(account)
            item[kSecValueData as String] = data
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.unexpectedStatus(added) }
        } else if status != errSecSuccess {
            throw Failure.unexpectedStatus(status)
        }
    }

    static func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unexpectedStatus(status) }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
