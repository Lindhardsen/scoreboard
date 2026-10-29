import Foundation
import Security

struct Credentials: Codable, Equatable, Sendable {
    var server: URL
    var username: String
    var token: String
}

protocol CredentialsStoring: Sendable {
    func load() -> Credentials?
    func save(_ c: Credentials) throws
    func clear()
}

struct KeychainError: Error {
    let status: OSStatus
}

/// Keeps server, username and upload token in one Keychain item. The password is never stored.
struct KeychainCredentialsStore: CredentialsStoring {
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.lindhardsen.scoreboard",
            kSecAttrAccount as String: "credentials",
        ]
    }

    func load() -> Credentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    func save(_ c: Credentials) throws {
        clear()
        var item = query
        item[kSecValueData as String] = try JSONEncoder().encode(c)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
