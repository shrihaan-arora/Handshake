import Foundation
import SwiftUI
import HandshakeCore

@MainActor
public final class DashboardViewModel: ObservableObject {
    @Published public var connectionState: ConnectionState
    @Published public var pairedMac: DeviceIdentity?
    @Published public var securityStatus: SecurityStatus
    @Published public var isPairingSheetPresented: Bool = false
    @Published public var isSecurityAuditPresented: Bool = false
    @Published public var phase1NoticeMessage: String? = nil

    public init() {
        // Initial mock state for Phase 1 UI demonstration
        let sampleMac = DeviceIdentity(
            id: UUID(),
            publicKeyHex: "f6b89c3140a32057d34199a0937c569a9e334df5d9e527f300c3c6f2df798f82",
            displayName: "Shrihaan's MacBook Pro",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 15.1"
        )

        self.pairedMac = sampleMac
        self.connectionState = .connected(transport: .localWiFi, peer: sampleMac)
        self.securityStatus = .standardSecure
    }

    public func handleLockMacTapped() {
        // Phase 1 Discipline: Do not claim or execute real remote command
        self.phase1NoticeMessage = "Lock Command (Phase 1 Preview): Wire-level encrypted command delivery will be activated in Phase 2 upon mutual TLS and BLE transport verification."
    }

    public func handleSleepMacTapped() {
        // Phase 1 Discipline: Do not claim or execute real remote command
        self.phase1NoticeMessage = "Sleep Command (Phase 1 Preview): Power management commands are stubbed in Phase 1 and will be enabled in Phase 2 with strict authorization checks."
    }

    public func handlePairNewDeviceTapped() {
        self.isPairingSheetPresented = true
    }

    public func handleSecurityAuditTapped() {
        self.isSecurityAuditPresented = true
    }

    public func dismissNotice() {
        self.phase1NoticeMessage = nil
    }
}
