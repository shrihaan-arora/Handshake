import Foundation
import SwiftUI
import HandshakeCore

@MainActor
public final class MacDashboardViewModel: ObservableObject {
    @Published public var isAvailableForControl: Bool = true
    @Published public var connectionState: ConnectionState
    @Published public var trustedDevices: [TrustRecord] = []
    @Published public var isPairingSheetPresented: Bool = false
    @Published public var activeInvitation: PairingInvitation?
    @Published public var securityStatus: SecurityStatus
    @Published public var recentAuditEvents: [String] = []

    public init() {
        // Sample host Mac identity
        let hostMac = DeviceIdentity(
            id: UUID(),
            publicKeyHex: "f6b89c3140a32057d34199a0937c569a9e334df5d9e527f300c3c6f2df798f82",
            displayName: "Shrihaan's MacBook Pro",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 15.1"
        )

        // Sample trusted client iPhone
        let samplePhone = DeviceIdentity(
            id: UUID(),
            publicKeyHex: "7a1b3c9e2057d34199a0937c569a9e334df5d9e527f300c3c6f2df798f82f6b8",
            displayName: "Shrihaan's iPhone 16 Pro",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "iOS 18.1"
        )

        self.trustedDevices = [
            TrustRecord(
                peer: samplePhone,
                pairedAt: Date().addingTimeInterval(-86400 * 3),
                lastSeenAt: Date()
            )
        ]

        self.connectionState = .connected(transport: .localWiFi, peer: samplePhone)
        self.securityStatus = .standardSecure
        self.recentAuditEvents = [
            "Hardware-backed identity key initialized in Keychain",
            "Local TLS listener configured for port 5894",
            "Zero-cloud enforcement confirmed: 0 outbound external sockets",
            "Paired device '\(samplePhone.displayName)' authenticated over local Wi-Fi"
        ]
    }

    public func toggleAvailability() {
        isAvailableForControl.toggle()
        if !isAvailableForControl {
            connectionState = .disconnected
            recentAuditEvents.insert("Mac host marked unavailable: local listeners suspended", at: 0)
        } else {
            recentAuditEvents.insert("Mac host marked available: listening on local Wi-Fi and BLE", at: 0)
        }
    }

    public func startPairingFlow() {
        let hostMac = DeviceIdentity(
            id: UUID(),
            publicKeyHex: "f6b89c3140a32057d34199a0937c569a9e334df5d9e527f300c3c6f2df798f82",
            displayName: "Shrihaan's MacBook Pro",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 15.1"
        )

        self.activeInvitation = PairingInvitation(
            hostIdentity: hostMac,
            ephemeralPublicKeyHex: UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            lifetimeSeconds: 120,
            verificationCode: "849 201"
        )
        self.isPairingSheetPresented = true
        recentAuditEvents.insert("Temporary pairing invitation generated (expires in 120s)", at: 0)
    }

    public func revokeDevice(at index: Int) {
        guard index < trustedDevices.count else { return }
        var record = trustedDevices[index]
        record.revoke()
        trustedDevices[index] = record
        recentAuditEvents.insert("Trust revoked for device '\(record.peer.displayName)'", at: 0)
    }
}
