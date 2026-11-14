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
        // Phase 1 Baseline: No active network connections or verified crypto sessions exist yet
        self.pairedMac = nil
        self.connectionState = .disconnected
        self.securityStatus = .unconfigured
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

