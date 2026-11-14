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

/// Represents the real-time connectivity lifecycle between local peers.
public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case discovering
    case connecting(transport: TransportType)
    case connected(transport: TransportType, peer: DeviceIdentity)
    case failed(reason: String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var connectedPeer: DeviceIdentity? {
        if case .connected(_, let peer) = self { return peer }
        return nil
    }

    public var transport: TransportType? {
        switch self {
        case .connecting(let transport): return transport
        case .connected(let transport, _): return transport
        default: return nil
        }
    }

    public var statusTitle: String {
        switch self {
        case .disconnected: return "Not Connected"
        case .discovering: return "Searching Nearby..."
        case .connecting(let transport): return "Connecting via \(transport.rawValue)..."
        case .connected(let transport, let peer): return "Connected to \(peer.displayName) (\(transport.rawValue))"
        case .failed: return "Connection Failed"
        }
    }

    public var statusDescription: String {
        switch self {
        case .disconnected:
            return "Ensure your paired Mac is awake and on the same local Wi-Fi or within Bluetooth range."
        case .discovering:
            return "Listening for local Bonjour and BLE advertisements."
        case .connecting(let transport):
            return "Negotiating mutual authentication over \(transport.rawValue)..."
        case .connected(let transport, _):
            return "Direct peer link established over \(transport.rawValue) with hardware-verified identity."
        case .failed(let reason):
            return reason
        }
    }

    public var sfSymbolName: String {
        switch self {
        case .disconnected: return "bolt.slash.fill"
        case .discovering: return "sparkle.magnifyingglass"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .connected: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}
