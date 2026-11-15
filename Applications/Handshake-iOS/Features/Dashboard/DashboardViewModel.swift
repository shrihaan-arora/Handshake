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
    @Published public var isSecurityAuditPresented: Bool = false
    @Published public var isForgetConfirmationPresented: Bool = false
    @Published public var alertMessage: String? = nil
    @Published public var alertTitle: String = "Handshake"
    @Published public var isExecutingCommand: Bool = false

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

    public func handleLockMacTapped() {
        guard !isExecutingCommand else { return }
        guard let mac = pairedMac, let client = client else {
            alertTitle = "No Paired Mac"
            alertMessage = "Please pair with your Mac before sending commands."
            return
        }

        isExecutingCommand = true
        commandStage = .sending(.lockScreen)
        connectionState = .discovering

        Task {
            defer {
                self.isExecutingCommand = false
                Task {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    await MainActor.run {
                        if !self.isExecutingCommand {
                            self.commandStage = .idle
                            self.connectionState = .connected(transport: .localWiFi, peer: mac)
                        }
                    }
                }
            }

            do {
                // 1. Discover Mac via local Bonjour targeting peer
                let (endpoint, _) = try await client.discoverMac(
                    serviceType: "_handshake._tcp",
                    targetPeer: mac,
                    timeoutSeconds: 6.0,
                    onStateChange: { [weak self] state in
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
                                self?.commandStage = .failed(.lockScreen, reason)
                            default:
                                break
                            }
                        }
                    }
                )

                // 2. Dispatch authenticated lock command and verify signed acknowledgment
                let ack = try await client.sendCommand(
                    .lockScreen,
                    to: endpoint,
                    trustedHostPublicKeyHex: mac.publicKeyHex,
                    preSharedKeyHex: self.activeTrustRecord?.preSharedKeyHex,
                    onStateChange: { [weak self] state in
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
                                self?.commandStage = .failed(.lockScreen, reason)
                            default:
                                break
                            }
                        }
                    }
                )

                switch ack.status {
                case .executed, .received:
                    self.commandStage = .completed(.lockScreen, "Display locked")
                    self.connectionState = .commandCompleted(.lockScreen)
                    self.alertTitle = "Screen Locked"
                    self.alertMessage = "Successfully locked \(mac.displayName)."
                case .rejected(let reason):
                    self.commandStage = .failed(.lockScreen, "Rejected: \(reason)")
                    self.connectionState = .commandFailed(reason: "Mac rejected command: \(reason)")
                    self.alertTitle = "Command Rejected"
                    self.alertMessage = "Mac rejected command: \(reason)"
                case .failed(let reason):
                    self.commandStage = .failed(.lockScreen, reason)
                    self.connectionState = .commandFailed(reason: "Mac failed to lock: \(reason)")
                    self.alertTitle = "Lock Failed"
                    self.alertMessage = "Mac failed to lock: \(reason)"
                }
            } catch let netErr as HandshakeClient.ClientError {
                let errReason: String
                switch netErr {
                case .macNotFound, .timeout:
                    errReason = "Discovery timed out. Ensure your Mac is on the same Wi-Fi."
                    self.connectionState = .macUnavailable(reason: errReason)
                    self.alertTitle = "Mac Unavailable"
                    self.alertMessage = "Could not discover \(mac.displayName) on local Wi-Fi. Verify both devices are on the same network and Handshake is running on your Mac."
                case .connectionFailed(let details):
                    errReason = "Connection failed: \(details)"
                    self.connectionState = .macUnavailable(reason: errReason)
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
                self.commandStage = .failed(.lockScreen, errReason)
            } catch {
                self.commandStage = .failed(.lockScreen, error.localizedDescription)
                self.connectionState = .commandFailed(reason: error.localizedDescription)
                self.alertTitle = "Command Failed"
                self.alertMessage = error.localizedDescription
            }
        }
    }

    public func handleSleepMacTapped() {
        guard !isExecutingCommand else { return }
        guard let mac = pairedMac, let client = client else {
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
                // 1. Discover Mac via local Bonjour targeting peer
                let (endpoint, _) = try await client.discoverMac(
                    serviceType: "_handshake._tcp",
                    targetPeer: mac,
                    timeoutSeconds: 6.0,
                    onStateChange: { [weak self] state in
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
                )

                // 2. Dispatch authenticated sleep command and verify signed acknowledgment
                let ack = try await client.sendCommand(
                    .sleep,
                    to: endpoint,
                    trustedHostPublicKeyHex: mac.publicKeyHex,
                    preSharedKeyHex: self.activeTrustRecord?.preSharedKeyHex,
                    onStateChange: { [weak self] state in
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
                )

                switch ack.status {
                case .executed, .received:
                    self.commandStage = .completed(.sleep, "Mac sleep initiated")
                    self.connectionState = .commandCompleted(.sleep)
                    self.alertTitle = "Sleep Initiated"
                    self.alertMessage = "\(mac.displayName) accepted sleep command. Mac will disconnect as it powers down."
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
                    errReason = "Discovery timed out. Ensure your Mac is on the same Wi-Fi."
                    self.connectionState = .macUnavailable(reason: errReason)
                    self.alertTitle = "Mac Unavailable"
                    self.alertMessage = "Could not discover \(mac.displayName) on local Wi-Fi. Verify both devices are on the same network and Handshake is running on your Mac."
                case .connectionFailed(let details):
                    errReason = "Connection failed: \(details)"
                    self.connectionState = .macUnavailable(reason: errReason)
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

    public func executePairing(
        invitation: PairingInvitation,
        onStageChange: (@Sendable (PairingStage) -> Void)? = nil,
        onSASDerived: @escaping @Sendable (String) async -> Bool
    ) async throws -> TrustRecord {
        guard let client = self.client else {
            throw HandshakeClient.ClientError.connectionFailed("Cryptographic client uninitialized")
        }
        return try await client.pair(
            with: invitation,
            trustStore: self.trustStore,
            onStageChange: onStageChange,
            onSASDerived: onSASDerived
        )
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
        guard let mac = pairedMac, let client = client else { return }
        guard !isExecutingCommand else { return }

        connectionState = .reconnecting

        Task {
            do {
                let (endpoint, _) = try await client.discoverMac(
                    serviceType: "_handshake._tcp",
                    targetPeer: mac,
                    timeoutSeconds: 5.0
                )
                await MainActor.run {
                    self.connectionState = .connected(transport: .localWiFi, peer: mac)
                }
            } catch {
                await MainActor.run {
                    self.connectionState = .connectionFailed(reason: "Mac companion not found on local Wi-Fi.")
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
