import Foundation

/// Transport layer category used for peer-to-peer data transmission.
public enum TransportType: String, Codable, Sendable, Equatable {
    case localWiFi = "Wi-Fi"
    case bluetoothLE = "BLE"
    case hybrid = "Wi-Fi + BLE"

    public var sfSymbolName: String {
        switch self {
        case .localWiFi: return "wifi"
        case .bluetoothLE: return "dot.radiowaves.left.and.right"
        case .hybrid: return "antenna.radiowaves.left.and.right"
        }
    }
}

/// Represents the real-time connectivity and command lifecycle between local peers.
/// Conforms to Section 11 verified progression states.
public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case discovering
    case macFound(peerName: String)
    case connectingSecurely
    case verifyingDevice
    case secureConnectionEstablished(peer: DeviceIdentity)
    case sendingCommand(CommandType)
    case commandAccepted(CommandType)
    case commandFailed(reason: String)
    case macUnavailable(reason: String)

    // Legacy/compatibility cases
    case connecting(transport: TransportType)
    case connected(transport: TransportType, peer: DeviceIdentity)
    case failed(reason: String)

    public var isConnected: Bool {
        switch self {
        case .connected, .secureConnectionEstablished:
            return true
        default:
            return false
        }
    }

    public var connectedPeer: DeviceIdentity? {
        switch self {
        case .connected(_, let peer):
            return peer
        case .secureConnectionEstablished(let peer):
            return peer
        default:
            return nil
        }
    }

    public var transport: TransportType? {
        switch self {
        case .connecting(let transport):
            return transport
        case .connected(let transport, _):
            return transport
        case .connectingSecurely, .verifyingDevice, .secureConnectionEstablished, .sendingCommand, .commandAccepted:
            return .localWiFi
        default:
            return nil
        }
    }

    public var statusTitle: String {
        switch self {
        case .disconnected:
            return "Not Connected"
        case .discovering:
            return "Searching for Paired Mac..."
        case .macFound(let name):
            return "Mac Found: \(name)"
        case .connectingSecurely:
            return "Connecting Securely..."
        case .verifyingDevice:
            return "Verifying Device..."
        case .secureConnectionEstablished(let peer):
            return "Secure Link: \(peer.displayName)"
        case .sendingCommand(let command):
            return "Sending \(command.displayName)..."
        case .commandAccepted(let command):
            return "\(command.displayName) Accepted"
        case .commandFailed(let reason):
            return "Command Failed: \(reason)"
        case .macUnavailable:
            return "Mac Unavailable"
        case .connecting(let transport):
            return "Connecting via \(transport.rawValue)..."
        case .connected(let transport, let peer):
            return "Connected to \(peer.displayName) (\(transport.rawValue))"
        case .failed:
            return "Connection Failed"
        }
    }

    public var statusDescription: String {
        switch self {
        case .disconnected:
            return "Ensure Handshake is open on your paired Mac on the same Wi-Fi network."
        case .discovering:
            return "Listening for local Bonjour service advertisement on TCP port 5894."
        case .macFound(let name):
            return "Discovered '\(name)' on the local network. Establishing peer connection."
        case .connectingSecurely:
            return "Negotiating local peer-to-peer TCP channel."
        case .verifyingDevice:
            return "Authenticating device identity keys against local Trust Store."
        case .secureConnectionEstablished(let peer):
            return "Direct authenticated AEAD channel established with '\(peer.displayName)'."
        case .sendingCommand(let command):
            return "Transmitting encrypted and signed \(command.displayName) envelope."
        case .commandAccepted(let command):
            return "\(command.displayName) verified and successfully executed on your Mac."
        case .commandFailed(let reason):
            return reason
        case .macUnavailable(let reason):
            return reason
        case .connecting(let transport):
            return "Connecting over \(transport.rawValue)..."
        case .connected(let transport, let peer):
            return "Authenticated connection to \(peer.displayName) over \(transport.rawValue)."
        case .failed(let reason):
            return reason
        }
    }

    public var sfSymbolName: String {
        switch self {
        case .disconnected:
            return "bolt.slash.fill"
        case .discovering:
            return "sparkle.magnifyingglass"
        case .macFound:
            return "macbook"
        case .connectingSecurely:
            return "lock.rotation"
        case .verifyingDevice:
            return "shield.lefthalf.filled"
        case .secureConnectionEstablished:
            return "lock.shield.fill"
        case .sendingCommand:
            return "arrow.up.circle.fill"
        case .commandAccepted:
            return "checkmark.circle.fill"
        case .commandFailed:
            return "xmark.circle.fill"
        case .macUnavailable:
            return "macbook.and.iphone"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .connected:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}
