import Foundation

/// Represents the platform and hardware category of a Handshake participant.
public enum DeviceType: String, Codable, Sendable, CaseIterable, CustomStringConvertible {
    case mac = "mac"
    case iPhone = "iPhone"
    case iPad = "iPad"
    case unknown = "unknown"

    public var description: String {
        switch self {
        case .mac: return "MacBook"
        case .iPhone: return "iPhone"
        case .iPad: return "iPad"
        case .unknown: return "Unknown Device"
        }
    }

    public var sfSymbolName: String {
        switch self {
        case .mac: return "macbook"
        case .iPhone: return "iphone"
        case .iPad: return "ipad"
        case .unknown: return "laptopcomputer.and.iphone"
        }
    }
}

