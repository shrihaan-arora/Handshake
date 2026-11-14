import Foundation
import Security

/// Secure, native Apple Keychain storage engine.
/// Configured with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// to guarantee keys and tokens never leave the physical device via iCloud backups.
public final class KeychainManager: Sendable {

    public static let shared = KeychainManager()

    public enum KeychainError: Error, LocalizedError, Equatable {
        case itemNotFound
        case duplicateItem
        case unexpectedStatus(OSStatus)
        case invalidData

        public var errorDescription: String? {
            switch self {
            case .itemNotFound:
                return "The requested item was not found in the Keychain."
            case .duplicateItem:
                return "An item with this key already exists in the Keychain."
            case .unexpectedStatus(let status):
                return "Keychain operation failed with OSStatus \(status)."
            case .invalidData:
                return "The data stored in the Keychain could not be parsed."
            }
        }
    }

    private let service: String

    public init(service: String = "com.handshake.security") {
        self.service = service
    }

    // MARK: - Generic Password / Data Storage

    /// Saves or updates raw data in the Keychain under the specified account key.
    public func save(data: Data, forAccount account: String) throws {
        // First delete any existing entry to ensure atomic update
        try? delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Retrieves raw data from the Keychain for the specified account key.
    public func retrieve(forAccount account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.invalidData
            }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Deletes the item for the specified account key from the Keychain.
    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Checks whether an item exists for the specified account key.
    public func contains(account: String) -> Bool {
        do {
            _ = try retrieve(forAccount: account)
            return true
        } catch {
            return false
        }
    }
}
