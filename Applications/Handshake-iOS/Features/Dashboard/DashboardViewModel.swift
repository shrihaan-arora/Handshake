import Foundation
import SwiftUI
import UIKit
import HandshakeCore

@MainActor
public final class DashboardViewModel: ObservableObject {
    @Published public var connectionState: ConnectionState = .disconnected
    @Published public var pairedMac: DeviceIdentity?
    @Published public var securityStatus: SecurityStatus = .unconfigured
    @Published public var isPairingSheetPresented: Bool = false
    @Published public var isBLEPairingSheetPresented: Bool = false
    @Published public var isConnectionDiagnosticsPresented: Bool = false
    @Published public var isSecurityAuditPresented: Bool = false
    @Published public var isForgetConfirmationPresented: Bool = false
    @Published public var alertMessage: String? = nil
    @Published public var alertTitle: String = "Handshake"
    @Published public var isExecutingCommand: Bool = false

    // MARK: - Bluetooth LE First-Time Pairing State
    @Published public var discoveredBLEHosts: [DiscoveredBLEHost] = []
    @Published public var isScanningBLE: Bool = false
    @Published public var blePairingStage: PairingStage = .notStarted
    @Published public var blePairingError: String? = nil
    @Published public var bleDerivedSAS: String? = nil
    @Published public var selectedBLEHost: DiscoveredBLEHost? = nil
    private var bleSASApprovalContinuation: CheckedContinuation<Bool, Never>? = nil

    public enum CommandExecutionStage: Equatable, Sendable {
        case idle
        case sending(CommandType)
        case executing(CommandType)
        case completed(CommandType, String)
        case failed(CommandType, String)

        public var stageLabel: String {
            switch self {
            case .idle: return ""
            case .sending: return "Sending"
            case .executing: return "Executing"
            case .completed: return "Completed"
            case .failed: return "Failed"
            }
        }

        public var command: CommandType? {
            switch self {
            case .idle: return nil
            case .sending(let cmd), .executing(let cmd), .completed(let cmd, _), .failed(let cmd, _):
                return cmd
            }
        }
    }

    @Published public var commandStage: CommandExecutionStage = .idle

    private var clientIdentity: CryptoIdentity?
    private let trustStore: TrustStore
    private var activeTrustRecord: TrustRecord?
    private let sequenceCounter = SequenceCounter()
    private var client: HandshakeClient?

    public init() {
        self.trustStore = TrustStore(storageAccount: "com.shrihaan.handshake.ios.truststore")
        self.connectionState = .disconnected
        self.securityStatus = .unconfigured
        if ProcessInfo.processInfo.arguments.contains("-openScanner") {
            self.isPairingSheetPresented = true
        }

        Task {
            await initializeIdentityAndTrust()
        }
    }

    private func initializeIdentityAndTrust() async {
        do {
            let identity = try CryptoIdentity.loadOrCreate(
                label: "com.shrihaan.handshake.ios.identity",
                displayName: UIDevice.current.name,
                deviceType: .iPhone,
                modelIdentifier: "iPhone16,1",
                systemVersion: UIDevice.current.systemVersion
            )
            self.clientIdentity = identity
            self.client = HandshakeClient(clientIdentity: identity, sequenceCounter: sequenceCounter)

            let records = await trustStore.allRecords()
            if let activeRecord = records.first(where: { !$0.isRevoked }) {
                self.activeTrustRecord = activeRecord
                self.pairedMac = activeRecord.peer
                self.securityStatus = SecurityStatus(
                    trustLevel: .paired,
                    isHardwareBacked: identity.isHardwareBacked,
                    isTransportEncrypted: true,
                    isApplicationEncrypted: true,
                    isReplayGuarded: true,
                    zeroCloudEnforced: true,
                    lastAuditedDate: Date()
                )
            } else {
                self.activeTrustRecord = nil
                self.pairedMac = nil
                self.securityStatus = SecurityStatus(
                    trustLevel: .unverified,
                    isHardwareBacked: identity.isHardwareBacked,
                    isTransportEncrypted: false,
                    isApplicationEncrypted: false,
                    isReplayGuarded: false,
                    zeroCloudEnforced: true,
                    lastAuditedDate: nil
                )
            }
        } catch {
            self.alertTitle = "Identity Error"
            self.alertMessage = "Failed to initialize cryptographic identity: \(error.localizedDescription)"
        }
    }

    // MARK: - Command Execution

    @available(*, deprecated, message: "Lock Screen is unsupported in V1; Sleep Mac is the primary control action.")
    public func handleLockMacTapped() {
        alertTitle = "Action Unavailable"
        alertMessage = "Lock Screen is unsupported in V1. Use Sleep Mac instead."
    }

    public func handleSleepMacTapped() {
        guard !isExecutingCommand else { return }
        guard let mac = pairedMac, let client = client, let trustRecord = activeTrustRecord else {
            alertTitle = "No Paired Mac"
            alertMessage = "Please pair with your Mac before sending commands."
            return
        }

        isExecutingCommand = true
        commandStage = .sending(.sleep)
        connectionState = .discovering

        Task {
            defer {
                self.isExecutingCommand = false
                Task {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    await MainActor.run {
                        if !self.isExecutingCommand {
                            self.commandStage = .idle
                            self.connectionState = .disconnected
                        }
                    }
                }
            }

            do {
                let masterPSK = await self.trustStore.retrievePreSharedKey(forPeerId: trustRecord.id)
                guard let masterPSK else {
                    throw HandshakeClient.ClientError.connectionFailed("Pairing key is missing from this iPhone. Re-pair only if the Mac also no longer recognizes this device.")
                }
                let stateCallback: @Sendable (ConnectionState) -> Void = { [weak self] state in
                    Task { @MainActor in
                        self?.connectionState = state
                        switch state {
                        case .sendingCommand(let cmd):
                            self?.commandStage = .sending(cmd)
                        case .executingCommand(let cmd):
                            self?.commandStage = .executing(cmd)
                        case .commandCompleted(let cmd):
                            self?.commandStage = .completed(cmd, "Confirmed on Mac")
                        case .commandFailed(let reason):
                            self?.commandStage = .failed(.sleep, reason)
                        default:
                            break
                        }
                    }
                }

                // Execute command using Wi-Fi first, falling back automatically to Bluetooth LE
                let (ack, transport) = try await client.executeCommandWithFallback(
                    .sleep,
                    to: mac,
                    masterPSK: masterPSK,
                    wiFiTimeoutSeconds: 2.5,
                    bleTimeoutSeconds: 5.0,
                    onStateChange: stateCallback
                )

                switch ack.status {
                case .accepted:
                    self.commandStage = .completed(.sleep, "Sleep request accepted (\(transport.rawValue))")
                    self.connectionState = .commandCompleted(.sleep)
                    self.alertTitle = "Sleep Request Accepted"
                    self.alertMessage = "\(mac.displayName) accepted the sleep request over \(transport.rawValue). The Mac may disconnect before physical sleep can be observed."
                case .received, .authenticated, .authorized, .sleepRequestIssued, .physicalSleepObserved, .executed:
                    self.commandStage = .failed(.sleep, "Unexpected sleep acknowledgement state")
                    self.connectionState = .commandFailed(reason: "Unexpected sleep acknowledgement state")
                    self.alertTitle = "Sleep Status Uncertain"
                    self.alertMessage = "The Mac returned an unexpected status; no physical-sleep claim was made."
                case .rejected(let reason):
                    self.commandStage = .failed(.sleep, "Rejected: \(reason)")
                    self.connectionState = .commandFailed(reason: "Mac rejected sleep: \(reason)")
                    self.alertTitle = "Command Rejected"
                    self.alertMessage = "Mac rejected sleep: \(reason)"
                case .failed(let reason):
                    self.commandStage = .failed(.sleep, reason)
                    self.connectionState = .commandFailed(reason: "Mac failed to sleep: \(reason)")
                    self.alertTitle = "Sleep Failed"
                    self.alertMessage = "Mac failed to sleep: \(reason)"
                }
            } catch let netErr as HandshakeClient.ClientError {
                let errReason: String
                switch netErr {
                case .macNotFound, .timeout:
                    errReason = "Discovery timed out. Ensure your Mac is nearby and Handshake is open."
                    self.connectionState = .macUnavailable(reason: errReason)
                    self.alertTitle = "Mac Unavailable"
                    self.alertMessage = "Could not discover \(mac.displayName) over local Wi-Fi or Bluetooth LE. Verify Handshake is running on your Mac."
                case .connectionFailed(let details):
                    errReason = "Connection failed: \(details)"
                    // A discovered peer can still reject or fail a fresh secure
                    // session (for example, if its locally stored pairing key is
                    // missing).  That is not evidence that the Mac is absent, so
                    // preserve the diagnostic state instead of showing the
                    // misleading "Mac Unavailable" banner.
                    self.connectionState = .commandFailed(reason: errReason)
                    self.alertTitle = "Connection Failed"
                    self.alertMessage = details
                case .invalidAcknowledgment:
                    errReason = "Security failure: Mac response failed signature verification."
                    self.connectionState = .commandFailed(reason: errReason)
                    self.alertTitle = "Security Failure"
                    self.alertMessage = "The response from \(mac.displayName) failed cryptographic verification."
                default:
                    errReason = netErr.localizedDescription
                    self.connectionState = .commandFailed(reason: errReason)
                    self.alertTitle = "Command Failed"
                    self.alertMessage = errReason
                }
                self.commandStage = .failed(.sleep, errReason)
            } catch {
                self.commandStage = .failed(.sleep, error.localizedDescription)
                self.connectionState = .commandFailed(reason: error.localizedDescription)
                self.alertTitle = "Command Failed"
                self.alertMessage = error.localizedDescription
            }
        }
    }

    public func handlePairNewDeviceTapped() {
        self.isPairingSheetPresented = true
    }

    public func handlePairViaBluetoothTapped() {
        // Initial pairing is always QR initiated. BLE is chosen automatically as
        // the transport after the scanned invitation's direct TCP path fails.
        self.isPairingSheetPresented = true
    }

    public func handleConnectionDiagnosticsTapped() {
        self.isConnectionDiagnosticsPresented = true
    }

    public func startBLEDiscovery() {
        guard let client = self.client else { return }
        self.discoveredBLEHosts = []
        self.isScanningBLE = true
        self.blePairingStage = .notStarted
        self.blePairingError = nil
        self.bleDerivedSAS = nil

        Task {
            do {
                try await client.scanForNearbyBLEHosts(timeoutSeconds: 8.0) { [weak self] host in
                    Task { @MainActor in
                        guard let self = self else { return }
                        if !self.discoveredBLEHosts.contains(where: { $0.id == host.id }) {
                            self.discoveredBLEHosts.append(host)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.blePairingError = error.localizedDescription
                }
            }
            await MainActor.run {
                self.isScanningBLE = false
            }
        }
    }

    public func pairWithSelectedBLEHost(_ host: DiscoveredBLEHost) {
        self.selectedBLEHost = host
        self.blePairingError = "Scan the Mac's QR invitation first. Bluetooth is selected automatically if its TCP endpoint cannot be reached."
    }

    public func approveBLEPairing() {
        bleSASApprovalContinuation?.resume(returning: true)
        bleSASApprovalContinuation = nil
    }

    public func rejectBLEPairing() {
        bleSASApprovalContinuation?.resume(returning: false)
        bleSASApprovalContinuation = nil
        self.blePairingStage = .pairingFailed(reason: "Pairing was rejected on this device.")
    }

    public func dismissBLEPairing() {
        bleSASApprovalContinuation?.resume(returning: false)
        bleSASApprovalContinuation = nil
        self.isBLEPairingSheetPresented = false
        self.blePairingStage = .notStarted
        self.bleDerivedSAS = nil
        self.selectedBLEHost = nil
    }

    public func executePairing(
        invitation: PairingInvitation,
        onStageChange: (@Sendable (PairingStage) -> Void)? = nil,
        onSASDerived: @escaping @Sendable (String) async -> Bool
    ) async throws -> TrustRecord {
        guard let client = self.client, let identity = self.clientIdentity else {
            throw HandshakeClient.ClientError.connectionFailed("Cryptographic client uninitialized")
        }
        do {
            return try await client.pair(
                with: invitation,
                trustStore: self.trustStore,
                onStageChange: onStageChange,
                onSASDerived: onSASDerived
            )
        } catch {
            // The QR invitation remains authoritative; BLE only replaces an
            // unreachable TCP carrier for the same signed pairing transcript.
            let bleClient = BLECentralClient(clientIdentity: identity, sequenceCounter: sequenceCounter)
            defer { bleClient.disconnect() }
            let peripheral = try await bleClient.discoverAndConnect(timeoutSeconds: 6.0)
            return try await bleClient.pairOverBLE(
                peripheral: peripheral,
                invitation: invitation,
                trustStore: trustStore,
                timeoutSeconds: 12.0,
                onStageChange: onStageChange,
                onSASDerived: onSASDerived
            )
        }
    }

    // MARK: - Disconnect & Reconnect Lifecycle

    public func handleDisconnectTapped() {
        guard !isExecutingCommand else { return }
        guard connectionState != .disconnected && connectionState != .disconnecting else { return }

        connectionState = .disconnecting

        Task {
            // Simulated brief grace to flush any pending network buffers and release ephemeral session keys
            try? await Task.sleep(nanoseconds: 250_000_000)
            await MainActor.run {
                self.connectionState = .disconnected
                self.alertTitle = "Disconnected"
                self.alertMessage = "Session terminated. Pairing records remain preserved for quick reconnection."
            }
        }
    }

    public func handleReconnectTapped() {
        guard let mac = pairedMac, let client = client, let identity = clientIdentity else { return }
        guard !isExecutingCommand else { return }

        connectionState = .reconnecting

        Task {
            // 1. Probe local Wi-Fi first
            do {
                _ = try await client.discoverMac(
                    serviceType: "_handshake._tcp",
                    targetPeer: mac,
                    timeoutSeconds: 2.5
                )
                await MainActor.run {
                    self.connectionState = .connected(transport: .localWiFi, peer: mac)
                }
                return
            } catch {
                // Wi-Fi unreachable, attempt BLE discovery
            }

            // 2. Probe Bluetooth LE
            await MainActor.run {
                self.connectionState = .connecting(transport: .bluetoothLE)
            }

            let bleClient = BLECentralClient(clientIdentity: identity, sequenceCounter: sequenceCounter)
            defer {
                bleClient.disconnect()
            }

            do {
                _ = try await bleClient.discoverAndConnect(
                    targetPeerPublicKeyHex: mac.publicKeyHex,
                    timeoutSeconds: 4.0
                )
                await MainActor.run {
                    self.connectionState = .connected(transport: .bluetoothLE, peer: mac)
                }
            } catch {
                await MainActor.run {
                    self.connectionState = .connectionFailed(reason: "Mac companion not found on local Wi-Fi or Bluetooth LE.")
                }
            }
        }
    }

    public func handleForgetDeviceTapped() {
        self.isForgetConfirmationPresented = true
    }

    public func confirmForgetDevice() {
        guard let record = activeTrustRecord else { return }
        Task {
            try? await trustStore.revoke(id: record.id)
            await MainActor.run {
                self.activeTrustRecord = nil
                self.pairedMac = nil
                self.connectionState = .disconnected
                self.securityStatus = SecurityStatus(
                    trustLevel: .unverified,
                    isHardwareBacked: self.clientIdentity?.isHardwareBacked ?? false,
                    isTransportEncrypted: false,
                    isApplicationEncrypted: false,
                    isReplayGuarded: false,
                    zeroCloudEnforced: true,
                    lastAuditedDate: nil
                )
                self.alertTitle = "Device Forgotten"
                self.alertMessage = "Device trust revoked. You will need to scan a new pairing QR code to reconnect."
            }
        }
    }

    public func handlePairingCompleted(record: TrustRecord) {
        self.activeTrustRecord = record
        self.pairedMac = record.peer
        self.securityStatus = SecurityStatus(
            trustLevel: .paired,
            isHardwareBacked: clientIdentity?.isHardwareBacked ?? false,
            isTransportEncrypted: true,
            isApplicationEncrypted: true,
            isReplayGuarded: true,
            zeroCloudEnforced: true,
            lastAuditedDate: Date()
        )
        self.connectionState = .connected(transport: .localWiFi, peer: record.peer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.isPairingSheetPresented = false
        }
        self.alertTitle = "Pairing Successful"
        self.alertMessage = "\(record.peer.displayName) has been cryptographically paired and pinned."
    }

    public func handleSecurityAuditTapped() {
        self.isSecurityAuditPresented = true
    }

    public func dismissNotice() {
        self.alertMessage = nil
    }
}
