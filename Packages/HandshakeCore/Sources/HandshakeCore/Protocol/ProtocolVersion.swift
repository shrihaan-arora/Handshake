import Foundation

/// Defines protocol versioning and compatibility constraints for Handshake.
public struct ProtocolVersion: Codable, Sendable, Equatable, Comparable {
    public let major: UInt8
    public let minor: UInt8

    public init(major: UInt8, minor: UInt8) {
        self.major = major
        self.minor = minor
    }

    /// Current operational protocol version (1.0).
    public static let current = ProtocolVersion(major: 1, minor: 0)

    /// Earliest backward-compatible protocol version accepted.
    public static let minimumSupported = ProtocolVersion(major: 1, minor: 0)

    public var isCompatible: Bool {
        major == ProtocolVersion.current.major && self >= ProtocolVersion.minimumSupported
    }

    public static func < (lhs: ProtocolVersion, rhs: ProtocolVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        return lhs.minor < rhs.minor
    }
}
