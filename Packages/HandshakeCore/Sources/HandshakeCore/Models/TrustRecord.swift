import Foundation

/// Persistent record representing a locally trusted peer device.
/// Stored in the local keychain/secure database.
public struct TrustRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let peer: DeviceIdentity
    public let pairedAt: Date
    public var lastSeenAt: Date
    public var isRevoked: Bool
    public var revokedAt: Date?
    public var authorizedCapabilities: [CommandType]

    public init(
        id: UUID = UUID(),
        peer: DeviceIdentity,
        pairedAt: Date = Date(),
        lastSeenAt: Date = Date(),
        isRevoked: Bool = false,
        revokedAt: Date? = nil,
        authorizedCapabilities: [CommandType] = CommandType.allCases
    ) {
        self.id = id
        self.peer = peer
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.isRevoked = isRevoked
        self.revokedAt = revokedAt
        self.authorizedCapabilities = authorizedCapabilities
    }

    /// Mark the device as revoked, preventing future incoming commands.
    public mutating func revoke() {
        self.isRevoked = true
        self.revokedAt = Date()
    }
}
