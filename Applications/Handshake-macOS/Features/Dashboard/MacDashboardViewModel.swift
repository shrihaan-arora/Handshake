import Foundation
import SwiftUI
import HandshakeCore

@MainActor
public final class MacDashboardViewModel: ObservableObject {
    @Published public var isAvailableForControl: Bool = true
    @Published public var connectionState: ConnectionState = .disconnected
    @Published public var trustedDevices: [TrustRecord] = []
    @Published public var isPairingSheetPresented: Bool = false
    @Published public var activeInvitation: PairingInvitation?
    @Published public var securityStatus: SecurityStatus = .unconfigured
    @Published public var recentAuditEvents: [String] = []

    private var hostIdentity: CryptoIdentity?
    private let trustStore: TrustStore
    private var server: HandshakeServer?
    private let lockEngine = MacLockEngine()
    private let sleepEngine = MacSleepEngine()

    public init() {
        self.trustStore = TrustStore(storageAccount: "com.shrihaan.handshake.mac.truststore")
        self.connectionState = .disconnected
        self.securityStatus = .unconfigured
        self.recentAuditEvents = [
            "Handshake V1 Companion Initialized",
            "Zero cloud infrastructure: local peer-to-peer transport only"
        ]

        Task {
            await initializeIdentityAndTrust()
        }
    }

    private func initializeIdentityAndTrust() async {
        do {
            let identity = try CryptoIdentity.loadOrCreate(
                label: "com.shrihaan.handshake.mac.identity",
                displayName: Host.current().localizedName ?? "MacBook",
                deviceType: .mac,
                modelIdentifier: "Mac15,3",
                systemVersion: ProcessInfo.processInfo.operatingSystemVersionString
            )
            self.hostIdentity = identity
            let records = await trustStore.allRecords()
            self.trustedDevices = records
            self.securityStatus = records.isEmpty ? .unconfigured : .standardSecure
            self.recentAuditEvents.insert("Cryptographic identity initialized (\(identity.identity.publicKeyHex.prefix(12))...)", at: 0)

            // Auto-start server if available and window is open
            if isAvailableForControl {
                startServer()
            }
        } catch {
            self.recentAuditEvents.insert("Identity initialization failed: \(error.localizedDescription)", at: 0)
        }
    }

    // MARK: - Server Lifecycle

    public func startServer() {
        guard isAvailableForControl, server == nil, let identity = hostIdentity else { return }

        let newServer = HandshakeServer(
            port: 5894,
            serviceType: "_handshake._tcp",
            hostIdentity: identity,
            trustStore: trustStore,
            executionHandler: { [weak self] message, peer in
                guard let self = self else { return .rejected("Mac host unavailable") }
                return await self.handleIncomingCommand(message, from: peer)
            }
        )
        self.server = newServer

        Task {
            do {
                try await newServer.start()
                self.connectionState = .discovering
                self.recentAuditEvents.insert("Local Bonjour listener active on TCP 5894 (_handshake._tcp)", at: 0)
            } catch {
                self.connectionState = .failed(reason: error.localizedDescription)
                self.recentAuditEvents.insert("Failed to start TCP listener: \(error.localizedDescription)", at: 0)
            }
        }
    }

    public func stopServer() {
        guard let activeServer = server else { return }
        Task {
            await activeServer.stop()
        }
        self.server = nil
        self.connectionState = .disconnected
        self.recentAuditEvents.insert("Local listener stopped", at: 0)
    }

    public func toggleAvailability() {
        isAvailableForControl.toggle()
        if !isAvailableForControl {
            stopServer()
        } else {
            startServer()
        }
    }

    // MARK: - Command Processing

    private func handleIncomingCommand(_ message: CommandMessage, from peer: DeviceIdentity) async -> CommandAcknowledgment.ExecutionStatus {
        switch message.command {
        case .lockScreen:
            recentAuditEvents.insert("Authenticated Lock command received from '\(peer.displayName)'", at: 0)
            let result = await lockEngine.lockDisplay()
            switch result {
            case .confirmedLocked:
                recentAuditEvents.insert("Display lock verified active", at: 0)
                return .executed
            case .invoked:
                recentAuditEvents.insert("Display lock invoked via System Events", at: 0)
                return .executed
            case .failed(let reason):
                recentAuditEvents.insert("Display lock failed: \(reason)", at: 0)
                return .failed(reason)
            case .received, .authenticated:
                return .received
            }

        case .sleep:
            recentAuditEvents.insert("Authenticated Sleep command received from '\(peer.displayName)'. Preparing sleep...", at: 0)
            if !sleepEngine.isSleepSupported() {
                recentAuditEvents.insert("Sleep rejected: hardware power management does not support sleep", at: 0)
                return .failed("System sleep not supported on this Mac")
            }
            // Return .executed so HandshakeServer signs acknowledgment, flushes TCP socket, and invokes triggerSleep()
            return .executed

        case .ping:
            recentAuditEvents.insert("Authenticated diagnostics ping from '\(peer.displayName)'", at: 0)
            return .executed

        case .queryStatus:
            recentAuditEvents.insert("Status query from '\(peer.displayName)'", at: 0)
            return .executed
        }
    }

    // MARK: - Pairing & Trust

    public func startPairingFlow() {
        guard let hostMac = hostIdentity?.identity else { return }

        let ephemeralKey = EphemeralKeyExchange()
        let ephemeralPublicHex = ephemeralKey.publicKeyHex
        let code = String(format: "%06d", Int.random(in: 100_000...999_999))

        self.activeInvitation = PairingInvitation(
            hostIdentity: hostMac,
            ephemeralPublicKeyHex: ephemeralPublicHex,
            lifetimeSeconds: 120,
            verificationCode: code
        )
        self.isPairingSheetPresented = true
        recentAuditEvents.insert("Single-use pairing invitation generated (expires in 120s)", at: 0)
    }

    public func revokeDevice(at index: Int) {
        guard index < trustedDevices.count else { return }
        let record = trustedDevices[index]
        Task {
            try? await trustStore.revoke(id: record.id)
            let updated = await trustStore.allRecords()
            self.trustedDevices = updated
            recentAuditEvents.insert("Trust permanently revoked for '\(record.peer.displayName)'", at: 0)
        }
    }
}
