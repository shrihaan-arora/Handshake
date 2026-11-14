import Foundation

/// Defines all allowable control actions executable over the Handshake peer protocol.
public enum CommandType: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Locks the macOS display immediately.
    case lockScreen = "lock_screen"
    /// Places the host Mac into low-power system sleep.
    case sleep = "sleep"
    /// Heartbeat diagnostic ping without system side effects.
    case ping = "ping"
    /// Query current Mac power, battery, and lock status.
    case queryStatus = "query_status"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lockScreen: return "Lock Screen"
        case .sleep: return "Put Mac to Sleep"
        case .ping: return "Diagnostics Ping"
        case .queryStatus: return "Query Status"
        }
    }

    public var description: String {
        switch self {
        case .lockScreen: return "Locks the Mac display immediately"
        case .sleep: return "Puts the Mac into low-power sleep"
        case .ping: return "Tests peer-to-peer transport latency"
        case .queryStatus: return "Retrieves lock and battery state"
        }
    }

    public var sfSymbolName: String {
        switch self {
        case .lockScreen: return "lock.fill"
        case .sleep: return "moon.fill"
        case .ping: return "waveform.path"
        case .queryStatus: return "info.circle"
        }
    }

    /// Indicates whether executing this command interrupts user workflow or locks the screen.
    public var isImpactful: Bool {
        switch self {
        case .lockScreen, .sleep:
            return true
        case .ping, .queryStatus:
            return false
        }
    }
}
