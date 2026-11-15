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
        authorizedCapabilities: [CommandType] = CommandType.allCases,
        preSharedKeyHex: String? = nil
    ) {
        self.id = id
        self.peer = peer
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.isRevoked = isRevoked
        self.revokedAt = revokedAt
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
}
