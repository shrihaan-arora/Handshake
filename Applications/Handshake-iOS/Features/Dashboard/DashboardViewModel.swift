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
                self.pairedMac = activeRecord.peer
                self.securityStatus = .standardSecure
            } else {
                self.pairedMac = nil
                self.securityStatus = .unconfigured
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
        connectionState = .connecting(transport: .localWiFi)

        Task {
            defer {
                self.isExecutingCommand = false
                self.connectionState = .disconnected
            }

            do {
                // 1. Discover Mac via local Bonjour
                let endpoint = try await client.discoverMac(serviceType: "_handshake._tcp", timeoutSeconds: 3.5)

                // 2. Dispatch authenticated lock command and verify signed acknowledgment
                let ack = try await client.sendCommand(
                    .lockScreen,
                    to: endpoint,
                    trustedHostPublicKeyHex: mac.publicKeyHex
                )

                switch ack.status {
                case .executed, .received:
                    self.alertTitle = "Screen Locked"
                    self.alertMessage = "Successfully locked \(mac.displayName)."
                case .rejected(let reason):
                    self.alertTitle = "Command Rejected"
                    self.alertMessage = "Mac rejected command: \(reason)"
                case .failed(let reason):
                    self.alertTitle = "Lock Failed"
                    self.alertMessage = "Mac failed to lock: \(reason)"
                }
            } catch {
                self.alertTitle = "Connection Failed"
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
        connectionState = .connecting(transport: .localWiFi)

        Task {
            defer {
                self.isExecutingCommand = false
                self.connectionState = .disconnected
            }

            do {
                // 1. Discover Mac via local Bonjour
                let endpoint = try await client.discoverMac(serviceType: "_handshake._tcp", timeoutSeconds: 3.5)

                // 2. Dispatch authenticated sleep command and verify signed acknowledgment
                let ack = try await client.sendCommand(
                    .sleep,
                    to: endpoint,
                    trustedHostPublicKeyHex: mac.publicKeyHex
                )

                switch ack.status {
                case .executed, .received:
                    self.alertTitle = "Sleep Initiated"
                    self.alertMessage = "\(mac.displayName) accepted sleep command. Mac will disconnect as it powers down."
                case .rejected(let reason):
                    self.alertTitle = "Command Rejected"
                    self.alertMessage = "Mac rejected sleep: \(reason)"
                case .failed(let reason):
                    self.alertTitle = "Sleep Failed"
                    self.alertMessage = "Mac failed to sleep: \(reason)"
                }
            } catch {
                self.alertTitle = "Connection Failed"
                self.alertMessage = error.localizedDescription
            }
        }
    }

    public func handlePairNewDeviceTapped() {
        self.isPairingSheetPresented = true
    }

    public func handleSecurityAuditTapped() {
        self.isSecurityAuditPresented = true
    }

    public func dismissNotice() {
        self.alertMessage = nil
    }
}
