import Foundation

/// Identity descriptor for an authenticated device in the Handshake trust domain.
/// Contains metadata and public cryptographic identity information.
/// Private keys are NEVER stored or represented in this model.
public struct DeviceIdentity: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let publicKeyHex: String
    public let displayName: String
    public let deviceType: DeviceType
    public let modelIdentifier: String
    public let systemVersion: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        publicKeyHex: String,
        displayName: String,
        deviceType: DeviceType,
        modelIdentifier: String,
        systemVersion: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.publicKeyHex = publicKeyHex
        self.displayName = displayName
        self.deviceType = deviceType
        self.modelIdentifier = modelIdentifier
        self.systemVersion = systemVersion
        self.createdAt = createdAt
    }

    /// Truncated human-readable fingerprint of the public key (e.g. "A1B2...3F4E")
    public var shortFingerprint: String {
        guard publicKeyHex.count >= 8 else { return publicKeyHex }
        let prefix = publicKeyHex.prefix(4)
        let suffix = publicKeyHex.suffix(4)
        return "\(prefix)...\(suffix)".uppercased()
    }
}
