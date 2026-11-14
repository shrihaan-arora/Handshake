import Foundation

/// Security posture assessment for the local peer-to-peer subsystem.
public struct SecurityStatus: Codable, Sendable, Equatable {
    public enum TrustLevel: String, Codable, Sendable {
        case unverified = "Unverified"
        case paired = "Paired & Pinned"
        case revoked = "Revoked"
    }

    public let trustLevel: TrustLevel
    public let isHardwareBacked: Bool
    public let isTransportEncrypted: Bool
    public let isApplicationEncrypted: Bool
    public let isReplayGuarded: Bool
    public let zeroCloudEnforced: Bool
    public let lastAuditedDate: Date?

    public init(
        trustLevel: TrustLevel = .unverified,
        isHardwareBacked: Bool = true,
        isTransportEncrypted: Bool = true,
        isApplicationEncrypted: Bool = true,
        isReplayGuarded: Bool = true,
        zeroCloudEnforced: Bool = true,
        lastAuditedDate: Date? = nil
    ) {
        self.trustLevel = trustLevel
        self.isHardwareBacked = isHardwareBacked
        self.isTransportEncrypted = isTransportEncrypted
        self.isApplicationEncrypted = isApplicationEncrypted
        self.isReplayGuarded = isReplayGuarded
        self.zeroCloudEnforced = zeroCloudEnforced
        self.lastAuditedDate = lastAuditedDate
    }

    public static let standardSecure = SecurityStatus(
        trustLevel: .paired,
        isHardwareBacked: true,
        isTransportEncrypted: true,
        isApplicationEncrypted: true,
        isReplayGuarded: true,
        zeroCloudEnforced: true,
        lastAuditedDate: Date()
    )

    public static let unconfigured = SecurityStatus(
        trustLevel: .unverified,
        isHardwareBacked: true,
        isTransportEncrypted: false,
        isApplicationEncrypted: false,
        isReplayGuarded: false,
        zeroCloudEnforced: true,
        lastAuditedDate: nil
    )
}

