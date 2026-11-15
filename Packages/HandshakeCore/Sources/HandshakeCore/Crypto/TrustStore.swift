import Foundation
import CryptoKit

/// Thread-safe persistent store for trusted peer devices.
/// Persists records securely via Keychain Services, ensuring trusted device identities
/// survive application restarts without cloud dependence.
public actor TrustStore {

    private let keychain: KeychainManager
    private let storageAccount: String
    private var records: [UUID: TrustRecord] = [:]

    public init(
        keychain: KeychainManager = .shared,
        storageAccount: String = "com.handshake.truststore"
    ) {
        self.keychain = keychain
        self.storageAccount = storageAccount
        self.records = Self.loadFromKeychain(keychain: keychain, account: storageAccount)
    }

    // MARK: - Persistence Helpers

    private static func loadFromKeychain(keychain: KeychainManager, account: String) -> [UUID: TrustRecord] {
        guard let data = try? keychain.retrieve(forAccount: account),
              let decoded = try? JSONDecoder().decode([TrustRecord].self, from: data) else {
            return [:]
        }
        var dict: [UUID: TrustRecord] = [:]
        for record in decoded {
            dict[record.id] = record
        }
        return dict
    }

    private func saveToKeychain() throws {
        let array = Array(records.values)
        let data = try JSONEncoder().encode(array)
        try keychain.save(data: data, forAccount: storageAccount)
    }

    // MARK: - Key Management (Keychain-Isolated Master Secrets)

    private func pskAccount(forPeerId id: UUID) -> String {
        "\(storageAccount).psk.\(id.uuidString)"
    }

    /// Stores the pairwise master secret in dedicated Keychain storage.
    public func savePreSharedKey(_ psk: SymmetricKey, forPeerId id: UUID) throws {
        let keyData = psk.withUnsafeBytes { Data($0) }
        try keychain.save(data: keyData, forAccount: pskAccount(forPeerId: id))
    }

    /// Retrieves the pairwise master secret from Keychain storage.
    public func retrievePreSharedKey(forPeerId id: UUID) -> SymmetricKey? {
        if let keyData = try? keychain.retrieve(forAccount: pskAccount(forPeerId: id)), keyData.count == 32 {
            return SymmetricKey(data: keyData)
        }
        // Legacy fallback if migrated record had it
        if let record = records[id], let hex = record.preSharedKeyHex, let data = Data(hexString: hex), data.count == 32 {
            return SymmetricKey(data: data)
        }
        return nil
    }

    /// Retrieves the pairwise master secret for a given peer public key.
    public func retrievePreSharedKey(forPublicKeyHex publicKeyHex: String) -> SymmetricKey? {
        guard let record = getRecord(publicKeyHex: publicKeyHex) else { return nil }
        return retrievePreSharedKey(forPeerId: record.id)
    }

    /// Securely deletes the pairwise master secret from Keychain upon revocation or removal.
    public func deletePreSharedKey(forPeerId id: UUID) {
        try? keychain.delete(account: pskAccount(forPeerId: id))
    }

    // MARK: - Query & Mutation

    /// Stores a new trusted device record or updates an existing one.
    public func addOrUpdate(_ record: TrustRecord) throws {
        var sanitized = record
        if let pskHex = record.preSharedKeyHex, let pskData = Data(hexString: pskHex), pskData.count == 32 {
            try? savePreSharedKey(SymmetricKey(data: pskData), forPeerId: record.id)
            sanitized.preSharedKeyHex = nil
        }
        records[sanitized.id] = sanitized
        try saveToKeychain()
    }

    /// Retrieves a trust record by the peer's record ID.
    public func getRecord(id: UUID) -> TrustRecord? {
        records[id]
    }

    /// Retrieves a trust record by the peer's public key hex.
    public func getRecord(publicKeyHex: String) -> TrustRecord? {
        records.values.first { $0.peer.publicKeyHex.lowercased() == publicKeyHex.lowercased() }
    }

    /// Verifies if a given device public key is trusted and not revoked.
    public func isDeviceTrusted(publicKeyHex: String) -> Bool {
        guard let record = getRecord(publicKeyHex: publicKeyHex) else { return false }
        return !record.isRevoked
    }

    /// Marks a trusted device as revoked, preventing future command authorization.
    public func revoke(id: UUID) throws {
        guard var record = records[id] else { return }
        record.revoke()
        records[id] = record
        deletePreSharedKey(forPeerId: id)
        try saveToKeychain()
    }

    /// Completely removes a device record from the trust store.
    public func remove(id: UUID) throws {
        records.removeValue(forKey: id)
        deletePreSharedKey(forPeerId: id)
        try saveToKeychain()
    }

    /// Updates the last seen timestamp of an active peer connection.
    public func updateLastSeen(id: UUID, date: Date = Date()) throws {
        guard var record = records[id] else { return }
        record.lastSeenAt = date
        records[id] = record
        try saveToKeychain()
    }

    /// Returns all registered trust records.
    public func allRecords() -> [TrustRecord] {
        Array(records.values)
    }

    /// Removes all records (e.g. for factory reset or test isolation).
    public func removeAll() throws {
        for id in records.keys {
            deletePreSharedKey(forPeerId: id)
        }
        records.removeAll()
        try keychain.delete(account: storageAccount)
    }
}
