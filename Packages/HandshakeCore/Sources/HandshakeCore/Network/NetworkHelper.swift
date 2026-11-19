import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Network utility helpers for local network interface resolution,
/// IP address retrieval, and service name normalization.
public enum NetworkHelper {

    /// Retrieves all active, non-loopback, non-link-local IPv4 addresses paired with interface names.
    public static func getAllLocalIPv4Addresses() -> [(interface: String, address: String)] {
        var results: [(interface: String, address: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for cursor in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = cursor.pointee
            let flags = Int32(interface.ifa_flags)
            // Interface must be UP and RUNNING, and NOT LOOPBACK
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0 else {
                continue
            }
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let name = String(cString: interface.ifa_name)
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                let ipString = String(cString: hostname)
                if !ipString.hasPrefix("127.") && !ipString.hasPrefix("169.254.") {
                    results.append((interface: name, address: ipString))
                }
            }
        }
        return results
    }

    /// Retrieves the local IPv4 address for Wi-Fi (`en0` or `en1`).
    /// Returns `nil` if no active Wi-Fi interface is configured.
    public static func getLocalWiFiAddress() -> String? {
        let all = getAllLocalIPv4Addresses()
        return all.first(where: { $0.interface == "en0" || $0.interface == "en1" })?.address
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
    /// 1. Personal Hotspot / USB tethering IPv4 address (172.20.10.x).
    /// 2. Active Wi-Fi IPv4 address (en0/en1).
    /// 3. Any active non-loopback local IPv4 address (e.g. en5, etc.).
    /// 4. Fallback to mDNS local hostname.
    public static func getPreferredHostAddress() -> String {
        let all = getAllLocalIPv4Addresses()

        // 1. Hotspot subnet (Wi-Fi or USB tethered)
        if let hotspot = all.first(where: { $0.address.hasPrefix("172.20.10.") }) {
            return hotspot.address
        }

        // 2. Wi-Fi interface
        if let wifi = all.first(where: { $0.interface == "en0" || $0.interface == "en1" }) {
            return wifi.address
        }

        // 3. Any active IPv4
        if let anyAddr = all.first {
            return anyAddr.address
        }

        // 4. mDNS hostname
        return getLocalHostName()
    }

    /// Normalizes a Bonjour service instance name by stripping mDNS disambiguation suffixes
    /// (e.g., "MacBook Air (5)" -> "MacBook Air" or "MacBook Air-2" -> "MacBook Air") and trimming whitespace.
    public static func normalizeServiceName(_ name: String) -> String {
        return name
            .replacingOccurrences(of: "(\\s*\\(\\d+\\)|\\s*-\\s*\\d+)$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
