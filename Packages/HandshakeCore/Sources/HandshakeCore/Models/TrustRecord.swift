import Foundation

/// Persistent record representing a locally trusted peer device.
/// Stored in the local keychain/secure database.
public struct TrustRecord: Codable, Sendable, Identifiable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let peer: DeviceIdentity
    public let pairedAt: Date
    public var lastSeenAt: Date
    public var isRevoked: Bool
    public var revokedAt: Date?
    /// Historical marker used when duplicate active records for one full
    /// cryptographic identity are consolidated. This is not a user revocation.
    public var supersededAt: Date?
    public var supersededByRecordId: UUID?
    public var authorizedCapabilities: [CommandType]

    /// Optional 256-bit pairwise master key representation.
    /// Notice: Sanitized and isolated in Keychain via TrustStore.
    public var preSharedKeyHex: String?

    public var description: String {
        "TrustRecord(id: \(id), peer: \(peer.displayName) [\(peer.shortFingerprint)], isRevoked: \(isRevoked), capabilities: \(authorizedCapabilities))"
    }

    public var debugDescription: String {
        "TrustRecord(id: \(id), peer: \(peer.displayName), isRevoked: \(isRevoked), hasPSK: \(preSharedKeyHex != nil))"
    }

    public init(
        id: UUID = UUID(),
        peer: DeviceIdentity,
        pairedAt: Date = Date(),
        lastSeenAt: Date = Date(),
        isRevoked: Bool = false,
        revokedAt: Date? = nil,
        supersededAt: Date? = nil,
        supersededByRecordId: UUID? = nil,
        authorizedCapabilities: [CommandType] = CommandType.allCases,
        preSharedKeyHex: String? = nil
    ) {
        self.id = id
        self.peer = peer
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.isRevoked = isRevoked
        self.revokedAt = revokedAt
        self.supersededAt = supersededAt
        self.supersededByRecordId = supersededByRecordId
        self.authorizedCapabilities = authorizedCapabilities
        self.preSharedKeyHex = preSharedKeyHex
    }

    /// Mark the device as revoked, preventing future incoming commands.
    public mutating func revoke() {
        self.isRevoked = true
        if self.revokedAt == nil {
            self.revokedAt = Date()
        }
    }

    public var isSuperseded: Bool {
        supersededAt != nil
    }

    /// An active record is the only state that may authorize commands.
    public var isActive: Bool {
        !isRevoked && !isSuperseded
    }

    public mutating func markSuperseded(by recordId: UUID, at date: Date = Date()) {
        guard !isRevoked, id != recordId else { return }
        supersededAt = date
        supersededByRecordId = recordId
    }
}
