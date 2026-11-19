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

    public enum MacPairingState: Equatable {
        case idle
        case advertising(invitation: PairingInvitation)
        case awaitingApproval(client: DeviceIdentity, sasCode: String)
        case completed(client: DeviceIdentity)
        case failed(reason: String)

        public static func == (lhs: MacPairingState, rhs: MacPairingState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.advertising(let a), .advertising(let b)): return a.id == b.id
            case (.awaitingApproval(let a, let s1), .awaitingApproval(let b, let s2)): return a.id == b.id && s1 == s2
            case (.completed(let a), .completed(let b)): return a.id == b.id
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    @Published public var pairingState: MacPairingState = .idle
    @Published public var commandLogs: [CommandLogRecord] = []
    @Published public var isAuditHistorySheetPresented: Bool = false
    private var pairingDecisionContinuation: CheckedContinuation<Bool, Never>? = nil

    private var hostIdentity: CryptoIdentity?
    private let trustStore: TrustStore
    private var server: HandshakeServer?
    private var bleHost: BLEPeripheralHost?
    private var activeHostPairingSession: HostPairingSession? = nil
    private let sleepEngine = MacSleepEngine()

    private let dbManager: DatabaseManager?
    private let commandLogRepository: CommandLogRepository?
    private let pairingEventRepository: PairingEventRepository?
    private let deviceSessionRepository: DeviceSessionRepository?

    public init() {
        self.trustStore = TrustStore(storageAccount: "com.shrihaan.handshake.mac.truststore")
        self.connectionState = .disconnected
        self.securityStatus = .unconfigured
        self.recentAuditEvents = [
            "Handshake V1 Companion Initialized",
            "Zero cloud infrastructure: local peer-to-peer transport only"
        ]

        do {
            let db = try DatabaseManager()
            self.dbManager = db
            self.commandLogRepository = CommandLogRepository(dbManager: db)
            self.pairingEventRepository = PairingEventRepository(dbManager: db)
            self.deviceSessionRepository = DeviceSessionRepository(dbManager: db)
        } catch {
            print("Failed to initialize database manager: \(error)")
            self.dbManager = nil
            self.commandLogRepository = nil
            self.pairingEventRepository = nil
            self.deviceSessionRepository = nil
        }

        refreshCommandLogs()

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
            self.securityStatus = records.isEmpty ?
                SecurityStatus(
                    trustLevel: .unverified,
                    isHardwareBacked: identity.isHardwareBacked,
                    isTransportEncrypted: false,
                    isApplicationEncrypted: false,
                    isReplayGuarded: false,
                    zeroCloudEnforced: true,
                    lastAuditedDate: nil
                ) :
                SecurityStatus(
                    trustLevel: .paired,
                    isHardwareBacked: identity.isHardwareBacked,
                    isTransportEncrypted: true,
                    isApplicationEncrypted: true,
                    isReplayGuarded: true,
                    zeroCloudEnforced: true,
                    lastAuditedDate: Date()
                )
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
            commandLogRepository: commandLogRepository,
            pairingEventRepository: pairingEventRepository,
            deviceSessionRepository: deviceSessionRepository,
            executionHandler: { [weak self] message, peer in
                guard let self = self else { return .rejected("Mac host unavailable") }
                let status = await self.handleIncomingCommand(message, from: peer)
                Task { @MainActor in
                    self.refreshCommandLogs()
                }
                return status
            }
        )
        self.server = newServer

        let newBleHost = BLEPeripheralHost(
            hostIdentity: identity,
            trustStore: trustStore,
            sleepEngine: sleepEngine,
            commandLogRepository: commandLogRepository,
            pairingEventRepository: pairingEventRepository,
            deviceSessionRepository: deviceSessionRepository,
            executionHandler: { [weak self] message, peer in
                guard let self = self else { return .rejected("Mac host unavailable") }
                let status = await self.handleIncomingCommand(message, from: peer)
                Task { @MainActor in
                    self.refreshCommandLogs()
                }
                return status
            }
        )
        self.bleHost = newBleHost

        Task {
            newBleHost.start()
            do {
                try await newServer.start()
                self.connectionState = .discovering
                self.recentAuditEvents.insert("Dual transport active: Bonjour TCP 5894 & CoreBluetooth Peripheral (\(identity.identity.displayName))", at: 0)
            } catch {
                self.connectionState = .failed(reason: error.localizedDescription)
                self.recentAuditEvents.insert("TCP listener failed: \(error.localizedDescription) (Bluetooth LE active)", at: 0)
            }
        }
    }

    public func stopServer() {
        if let activeServer = server {
            Task {
                await activeServer.stop()
            }
            self.server = nil
        }
        if let activeBle = bleHost {
            activeBle.stop()
            self.bleHost = nil
        }
        self.connectionState = .disconnected
        self.recentAuditEvents.insert("Local listener and Bluetooth peripheral stopped", at: 0)
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
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timeStr = formatter.string(from: message.timestamp)
        let shortId = String(message.id.uuidString.prefix(8))

        switch message.command {
        case .lockScreen:
            recentAuditEvents.insert("[\(timeStr)] Rejected unsupported Lock command from '\(peer.displayName)' (#\(shortId))", at: 0)
            return .rejected("Lock Screen command is unsupported in V1")

        case .sleep:
            recentAuditEvents.insert("[\(timeStr)] Authenticated Sleep received from '\(peer.displayName)' (#\(shortId))", at: 0)
            if !sleepEngine.isSleepSupported() {
                recentAuditEvents.insert("[\(timeStr)] Sleep rejected: hardware power management does not support sleep", at: 0)
                return .failed("System sleep not supported on this Mac")
            }
            recentAuditEvents.insert("[\(timeStr)] Sleep prepared: signing acknowledgment and flushing transport", at: 0)
            // The transport acknowledgement is sent before the system is asked
            // to sleep, so it must report acceptance rather than a false success.
            return .accepted

        case .ping:
            recentAuditEvents.insert("[\(timeStr)] Authenticated diagnostics ping from '\(peer.displayName)' (#\(shortId))", at: 0)
            return .executed

        case .queryStatus:
            recentAuditEvents.insert("[\(timeStr)] Status query from '\(peer.displayName)' (#\(shortId))", at: 0)
            return .executed
        }
    }

    // MARK: - Pairing & Trust

    public func startPairingFlow() {
        guard let host = hostIdentity else { return }

        let preferredHost = NetworkHelper.getPreferredHostAddress()
        let hostSession = HostPairingSession(
            hostIdentity: host,
            lifetimeSeconds: 120,
            localPort: 5894,
            serviceName: "Handshake-Host",
            hostAddress: preferredHost
        )
        self.activeHostPairingSession = hostSession
        self.activeInvitation = hostSession.invitation
        self.pairingState = .advertising(invitation: hostSession.invitation)
        self.isPairingSheetPresented = true

        _ = try? self.pairingEventRepository?.insert(PairingEventRecord(
            peerDeviceId: host.identity.id.uuidString,
            peerDeviceName: host.identity.displayName,
            eventType: "pairing_initiated",
            result: "advertising"
        ))

        let approvalHandler: HandshakeServer.PairingApprovalHandler = { [weak self] client, sasCode in
            guard let self = self else { return false }
            return await withCheckedContinuation { continuation in
                Task { @MainActor in
                    self.pairingDecisionContinuation = continuation
                    self.pairingState = .awaitingApproval(client: client, sasCode: sasCode)
                    self.recentAuditEvents.insert("Bilateral pairing requested by '\(client.displayName)'. Awaiting verification.", at: 0)
                }
            }
        }

        Task {
            await self.server?.setActivePairingSession(hostSession, approvalHandler: approvalHandler)
        }
        self.bleHost?.setActivePairingSession(hostSession, approvalHandler: approvalHandler)
        recentAuditEvents.insert("Single-use pairing invitation generated (expires in 120s) with host \(preferredHost)", at: 0)
        recentAuditEvents.insert("Bluetooth LE advertising ready as a QR-initiated pairing fallback: '\(host.identity.displayName)'", at: 0)
    }

    public func approvePairing() {
        pairingDecisionContinuation?.resume(returning: true)
        pairingDecisionContinuation = nil
        if case .awaitingApproval(let client, _) = pairingState {
            pairingState = .completed(client: client)
            _ = try? pairingEventRepository?.insert(PairingEventRecord(
                peerDeviceId: client.id.uuidString,
                peerDeviceName: client.displayName,
                eventType: "pairing_approved",
                result: "success"
            ))
            recentAuditEvents.insert("Bilateral pairing approved for '\(client.displayName)'. Established in TrustStore.", at: 0)
            Task {
                let updated = await trustStore.allRecords()
                self.trustedDevices = updated
                self.refreshCommandLogs()
            }
        }
    }

    public func rejectPairing() {
        if case .awaitingApproval(let client, _) = pairingState {
            _ = try? pairingEventRepository?.insert(PairingEventRecord(
                peerDeviceId: client.id.uuidString,
                peerDeviceName: client.displayName,
                eventType: "pairing_rejected",
                result: "rejected"
            ))
        }
        pairingDecisionContinuation?.resume(returning: false)
        pairingDecisionContinuation = nil
        pairingState = .failed(reason: "Pairing was rejected on this Mac.")
        recentAuditEvents.insert("Pairing rejected by host user.", at: 0)
        refreshCommandLogs()
    }

    public func refreshCommandLogs() {
        guard let repo = commandLogRepository else { return }
        do {
            let logs = try repo.fetchRecent(limit: 100)
            self.commandLogs = logs
        } catch {
            print("Failed to fetch command logs: \(error)")
        }
    }

    public func dismissPairingFlow() {
        if let continuation = pairingDecisionContinuation {
            continuation.resume(returning: false)
            pairingDecisionContinuation = nil
        }
        Task {
            await self.server?.setActivePairingSession(nil)
        }
        self.bleHost?.setActivePairingSession(nil)
        self.activeHostPairingSession = nil
        self.activeInvitation = nil
        self.pairingState = .idle
        self.isPairingSheetPresented = false
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
