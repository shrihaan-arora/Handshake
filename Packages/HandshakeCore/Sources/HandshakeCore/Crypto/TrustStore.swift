import Foundation

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

    // MARK: - Query & Mutation

    /// Stores a new trusted device record or updates an existing one.
    public func addOrUpdate(_ record: TrustRecord) throws {
        records[record.id] = record
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
        try saveToKeychain()
    }

    /// Completely removes a device record from the trust store.
    public func remove(id: UUID) throws {
        records.removeValue(forKey: id)
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
        records.removeAll()
        try keychain.delete(account: storageAccount)
    }
}
