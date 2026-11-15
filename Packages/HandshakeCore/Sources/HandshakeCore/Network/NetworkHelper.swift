import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Network utility helpers for local network interface resolution,
/// IP address retrieval, and service name normalization.
public enum NetworkHelper {

    /// Retrieves the local IPv4 address for Wi-Fi (`en0` or `en1`).
    /// Returns `nil` if no active Wi-Fi interface is configured.
    public static func getLocalWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        let targetInterfaces = ["en0", "en1"]

        for cursor in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = cursor.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if targetInterfaces.contains(name) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    if result == 0 {
                        let ipString = String(cString: hostname)
                        if !ipString.hasPrefix("127.") {
                            address = ipString
                            break
                        }
                    }
                }
            }
        }
        return address
    }

    /// Returns the local mDNS host name (e.g., `MacBook-Air.local`).
    public static func getLocalHostName() -> String {
        let rawName = ProcessInfo.processInfo.hostName
        if !rawName.contains(".") {
            return "\(rawName).local"
        }
        return rawName
    }

    /// Returns the preferred host address for local peer-to-peer connection:
    /// Wi-Fi IPv4 address first, falling back to mDNS hostname.
    public static func getPreferredHostAddress() -> String {
        return getLocalWiFiAddress() ?? getLocalHostName()
    }

    /// Normalizes a Bonjour service instance name by stripping mDNS disambiguation suffixes
    /// (e.g., "MacBook Air (5)" -> "MacBook Air" or "MacBook Air-2" -> "MacBook Air") and trimming whitespace.
    public static func normalizeServiceName(_ name: String) -> String {
        return name
            .replacingOccurrences(of: "(\\s*\\(\\d+\\)|\\s*-\\s*\\d+)$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
