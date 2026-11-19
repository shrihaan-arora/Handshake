import Foundation
import CryptoKit

/// Thread-safe persistent store for trusted peer devices.
/// Persists records securely via Keychain Services, ensuring trusted device identities
/// survive application restarts without cloud dependence.
public actor TrustStore {

    public enum TrustStoreError: Error, LocalizedError, Equatable {
        case revokedRecordCannotBeReactivated

        public var errorDescription: String? {
            switch self {
            case .revokedRecordCannotBeReactivated:
                return "A revoked trust record cannot be reactivated in place. Complete a new approved pairing to establish a new record."
            }
        }
    }

    private let keychain: KeychainManager
    private let storageAccount: String
    private var records: [UUID: TrustRecord] = [:]

    public init(
        keychain: KeychainManager = .shared,
        storageAccount: String = "com.handshake.truststore"
    ) {
        self.keychain = keychain
        self.storageAccount = storageAccount
        let loaded = Self.loadFromKeychain(keychain: keychain, account: storageAccount)
        let consolidated = Self.consolidateLegacyActiveDuplicates(loaded)
        self.records = consolidated

        // A single Keychain item holds the serialized record set. Persisting
        // this non-destructive migration atomically keeps the originals for
        // audit while making ambiguous old active records non-authorizing.
        if loaded != consolidated, let data = try? JSONEncoder().encode(Array(consolidated.values)) {
            try? keychain.save(data: data, forAccount: storageAccount)
        }
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
        let array = allRecords()
        let data = try JSONEncoder().encode(array)
        try keychain.save(data: data, forAccount: storageAccount)
    }

    private func records(matchingPublicKeyHex publicKeyHex: String) -> [TrustRecord] {
        let normalized = publicKeyHex.lowercased()
        return records.values.filter { $0.peer.publicKeyHex.lowercased() == normalized }
    }

    private static func recordsByNewestFirst(_ candidates: [TrustRecord]) -> [TrustRecord] {
        candidates.sorted {
            if $0.pairedAt != $1.pairedAt { return $0.pairedAt > $1.pairedAt }
            if $0.lastSeenAt != $1.lastSeenAt { return $0.lastSeenAt > $1.lastSeenAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func consolidateLegacyActiveDuplicates(_ source: [UUID: TrustRecord]) -> [UUID: TrustRecord] {
        var consolidated = source
        let fullPublicKeys = Set(source.values.map { $0.peer.publicKeyHex.lowercased() })

        for publicKey in fullPublicKeys {
            let active = recordsByNewestFirst(
                consolidated.values.filter {
                    $0.peer.publicKeyHex.lowercased() == publicKey && $0.isActive
                }
            )
            guard let canonical = active.first, active.count > 1 else { continue }

            let timestamp = Date()
            for duplicate in active.dropFirst() {
                var superseded = duplicate
                superseded.markSuperseded(by: canonical.id, at: timestamp)
                consolidated[superseded.id] = superseded
            }
        }
        return consolidated
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
    @discardableResult
    public func addOrUpdate(_ record: TrustRecord) throws -> TrustRecord {
        if let existing = records[record.id], existing.isRevoked, !record.isRevoked {
            throw TrustStoreError.revokedRecordCannotBeReactivated
        }

        // Pairing creates a fresh input record, but an already active full
        // public key must retain its canonical record ID. This prevents a
        // second active record from being created for the same identity.
        let activeMatches = Self.recordsByNewestFirst(
            records(matchingPublicKeyHex: record.peer.publicKeyHex).filter(\.isActive)
        )
        let canonicalId = activeMatches.first?.id ?? record.id
        var stored = TrustRecord(
            id: canonicalId,
            peer: record.peer,
            pairedAt: record.pairedAt,
            lastSeenAt: record.lastSeenAt,
            isRevoked: record.isRevoked,
            revokedAt: record.revokedAt,
            authorizedCapabilities: record.authorizedCapabilities,
            preSharedKeyHex: record.preSharedKeyHex
        )

        if let pskHex = stored.preSharedKeyHex,
           let pskData = Data(hexString: pskHex), pskData.count == 32 {
            try savePreSharedKey(SymmetricKey(data: pskData), forPeerId: stored.id)
            stored.preSharedKeyHex = nil
        }
        records[stored.id] = stored

        // Preserve legacy duplicate records and their history, but ensure only
        // the canonical full-key record can remain active or authorize calls.
        let supersededAt = Date()
        for duplicate in records(matchingPublicKeyHex: stored.peer.publicKeyHex)
        where duplicate.id != stored.id && duplicate.isActive {
            var updated = duplicate
            updated.markSuperseded(by: stored.id, at: supersededAt)
            records[updated.id] = updated
        }

        try saveToKeychain()
        return stored
    }

    /// Retrieves a trust record by the peer's record ID.
    public func getRecord(id: UUID) -> TrustRecord? {
        records[id]
    }

    /// Retrieves a trust record by the peer's public key hex.
    public func getRecord(publicKeyHex: String) -> TrustRecord? {
        let matches = records(matchingPublicKeyHex: publicKeyHex)
        if let active = Self.recordsByNewestFirst(matches.filter(\.isActive)).first {
            return active
        }
        // Keeping a revoked match observable produces an explicit revoked
        // rejection, never a fallback based on names or fingerprint prefixes.
        return Self.recordsByNewestFirst(matches.filter(\.isRevoked)).first
    }

    /// Verifies if a given device public key is trusted and not revoked.
    public func isDeviceTrusted(publicKeyHex: String) -> Bool {
        guard let record = getRecord(publicKeyHex: publicKeyHex) else { return false }
        return record.isActive
    }

    /// Marks a trusted device as revoked, preventing future command authorization.
    public func revoke(id: UUID) throws {
        guard var record = records[id] else { return }
        record.revoke()
        records[id] = record
        try saveToKeychain()
        // Once revocation is durable, discard its PSK. A deletion failure can
        // never leave the device authorized.
        deletePreSharedKey(forPeerId: id)
    }

    /// Completely removes a device record from the trust store.
    public func remove(id: UUID) throws {
        records.removeValue(forKey: id)
        deletePreSharedKey(forPeerId: id)
        try saveToKeychain()
    }

    /// Updates the last seen timestamp of an active peer connection.
    public func updateLastSeen(id: UUID, date: Date = Date()) throws {
        guard var record = records[id], record.isActive else { return }
        record.lastSeenAt = date
        records[id] = record
        try saveToKeychain()
    }

    /// Returns all registered trust records.
    public func allRecords() -> [TrustRecord] {
        records.values.sorted {
            let lhsRank = $0.isActive ? 0 : ($0.isRevoked ? 1 : 2)
            let rhsRank = $1.isActive ? 0 : ($1.isRevoked ? 1 : 2)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if $0.pairedAt != $1.pairedAt { return $0.pairedAt > $1.pairedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
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
