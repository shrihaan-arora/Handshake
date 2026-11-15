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
    @Published public var alertMessage: String? = nil
    @Published public var alertTitle: String = "Handshake"
    @Published public var isExecutingCommand: Bool = false

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
        connectionState = .discovering

        Task {
            defer {
                self.isExecutingCommand = false
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await MainActor.run {
                        if !self.isExecutingCommand {
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
                    timeoutSeconds: 3.5,
                    onStateChange: { [weak self] state in
                        Task { @MainActor in
                            self?.connectionState = state
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
                        }
                    }
                )

                switch ack.status {
                case .executed, .received:
                    self.alertTitle = "Screen Locked"
                    self.alertMessage = "Successfully locked \(mac.displayName)."
                case .rejected(let reason):
                    self.connectionState = .commandFailed(reason: "Mac rejected command: \(reason)")
                    self.alertTitle = "Command Rejected"
                    self.alertMessage = "Mac rejected command: \(reason)"
                case .failed(let reason):
                    self.connectionState = .commandFailed(reason: "Mac failed to lock: \(reason)")
                    self.alertTitle = "Lock Failed"
                    self.alertMessage = "Mac failed to lock: \(reason)"
                }
            } catch let netErr as HandshakeClient.ClientError {
                switch netErr {
                case .macNotFound, .timeout:
                    self.connectionState = .macUnavailable(reason: "Discovery timed out. Ensure your Mac is on the same Wi-Fi.")
                    self.alertTitle = "Mac Unavailable"
                    self.alertMessage = "Could not discover \(mac.displayName) on local Wi-Fi. Verify both devices are on the same network and Handshake is running on your Mac."
                case .connectionFailed(let details):
                    self.connectionState = .macUnavailable(reason: "Connection failed: \(details)")
                    self.alertTitle = "Connection Failed"
                    self.alertMessage = details
                case .invalidAcknowledgment:
                    self.connectionState = .commandFailed(reason: "Security failure: Mac response failed signature verification.")
                    self.alertTitle = "Security Failure"
                    self.alertMessage = "The response from \(mac.displayName) failed cryptographic verification."
                default:
                    self.connectionState = .commandFailed(reason: netErr.localizedDescription)
                    self.alertTitle = "Command Failed"
                    self.alertMessage = netErr.localizedDescription
                }
            } catch {
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
        connectionState = .discovering

        Task {
            defer {
                self.isExecutingCommand = false
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await MainActor.run {
                        if !self.isExecutingCommand {
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
                    timeoutSeconds: 3.5,
                    onStateChange: { [weak self] state in
                        Task { @MainActor in
                            self?.connectionState = state
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
                        }
                    }
                )

                switch ack.status {
                case .executed, .received:
                    self.alertTitle = "Sleep Initiated"
                    self.alertMessage = "\(mac.displayName) accepted sleep command. Mac will disconnect as it powers down."
                case .rejected(let reason):
                    self.connectionState = .commandFailed(reason: "Mac rejected sleep: \(reason)")
                    self.alertTitle = "Command Rejected"
                    self.alertMessage = "Mac rejected sleep: \(reason)"
                case .failed(let reason):
                    self.connectionState = .commandFailed(reason: "Mac failed to sleep: \(reason)")
                    self.alertTitle = "Sleep Failed"
                    self.alertMessage = "Mac failed to sleep: \(reason)"
                }
            } catch let netErr as HandshakeClient.ClientError {
                switch netErr {
                case .macNotFound, .timeout:
                    self.connectionState = .macUnavailable(reason: "Discovery timed out. Ensure your Mac is on the same Wi-Fi.")
                    self.alertTitle = "Mac Unavailable"
                    self.alertMessage = "Could not discover \(mac.displayName) on local Wi-Fi. Verify both devices are on the same network and Handshake is running on your Mac."
                case .connectionFailed(let details):
                    self.connectionState = .macUnavailable(reason: "Connection failed: \(details)")
                    self.alertTitle = "Connection Failed"
                    self.alertMessage = details
                case .invalidAcknowledgment:
                    self.connectionState = .commandFailed(reason: "Security failure: Mac response failed signature verification.")
                    self.alertTitle = "Security Failure"
                    self.alertMessage = "The response from \(mac.displayName) failed cryptographic verification."
                default:
                    self.connectionState = .commandFailed(reason: netErr.localizedDescription)
                    self.alertTitle = "Command Failed"
                    self.alertMessage = netErr.localizedDescription
                }
            } catch {
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
        onSASDerived: @escaping @Sendable (String) async -> Bool
    ) async throws -> TrustRecord {
        guard let client = self.client else {
            throw HandshakeClient.ClientError.connectionFailed("Cryptographic client uninitialized")
        }
        return try await client.pair(with: invitation, trustStore: self.trustStore, onSASDerived: onSASDerived)
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
        self.isPairingSheetPresented = false
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
