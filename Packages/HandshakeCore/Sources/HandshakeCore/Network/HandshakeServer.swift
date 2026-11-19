import Foundation
import Network
import CryptoKit

/// Thread-safe, bounded, deterministic FIFO replay cache for message and session identifiers.
/// Provides O(1) membership lookup with strict memory bounds and deterministic oldest-first eviction.
private struct BoundedReplayCache: Sendable {
    private let capacity: Int
    private var order: [UUID] = []
    private var set: Set<UUID> = []

    init(capacity: Int) {
        self.capacity = capacity
        self.order.reserveCapacity(capacity)
    }

    func contains(_ id: UUID) -> Bool {
        set.contains(id)
    }

    /// Returns true if the ID is fresh (inserted), false if it was already seen (replay).
    mutating func insertIfFresh(_ id: UUID) -> Bool {
        if set.contains(id) {
            return false
        }
        if order.count >= capacity {
            let oldest = order.removeFirst()
            set.remove(oldest)
        }
        order.append(id)
        set.insert(id)
        return true
    }

    mutating func removeAll() {
        order.removeAll(keepingCapacity: true)
        set.removeAll(keepingCapacity: true)
    }
}

/// Local peer-to-peer TCP server for the host Mac companion.
/// Advertises `_handshake._tcp` via Bonjour and receives authenticated commands
/// strictly while the application's main window remains open.
public actor HandshakeServer {

    public typealias CommandExecutionHandler = @Sendable (CommandMessage, DeviceIdentity) async -> CommandAcknowledgment.ExecutionStatus
    public typealias PairingApprovalHandler = @Sendable (DeviceIdentity, String) async -> Bool

    public enum ServerError: Error, LocalizedError {
        case listenerCreationFailed(String)
        case alreadyRunning
        case notRunning

        public var errorDescription: String? {
            switch self {
            case .listenerCreationFailed(let msg): return "Failed to create local TCP listener: \(msg)"
            case .alreadyRunning: return "HandshakeServer is already running."
            case .notRunning: return "HandshakeServer is not running."
            }
        }
    }

    public nonisolated let port: UInt16
    public nonisolated let serviceType: String
    private let hostIdentity: CryptoIdentity
    private let trustStore: TrustStore
    private let initialSequenceCounter: SequenceCounter
    private var peerSequenceCounters: [String: SequenceCounter] = [:]
    private var recentSessionIds = BoundedReplayCache(capacity: 1000)
    private var recentCommandIds = BoundedReplayCache(capacity: 2000)
    private var initialCounterAssigned: Bool = false
    private let executionHandler: CommandExecutionHandler
    private let commandLogRepository: CommandLogRepository?
    private let pairingEventRepository: PairingEventRepository?
    private let deviceSessionRepository: DeviceSessionRepository?
    #if os(macOS)
    private let sleepEngine: MacSleepEngine
    #endif

    private var listener: NWListener?
    private var running: Bool = false
    private var activePairingSession: HostPairingSession? = nil
    private var pairingApprovalHandler: PairingApprovalHandler? = nil

#if os(macOS)
    public init(
        port: UInt16 = 5894,
        serviceType: String = "_handshake._tcp",
        hostIdentity: CryptoIdentity,
        trustStore: TrustStore,
        sequenceCounter: SequenceCounter = SequenceCounter(),
        sleepEngine: MacSleepEngine = MacSleepEngine(),
        commandLogRepository: CommandLogRepository? = nil,
        pairingEventRepository: PairingEventRepository? = nil,
        deviceSessionRepository: DeviceSessionRepository? = nil,
        executionHandler: @escaping CommandExecutionHandler
    ) {
        self.port = port
        self.serviceType = serviceType
        self.hostIdentity = hostIdentity
        self.trustStore = trustStore
        self.initialSequenceCounter = sequenceCounter
        self.sleepEngine = sleepEngine
        self.commandLogRepository = commandLogRepository
        self.pairingEventRepository = pairingEventRepository
        self.deviceSessionRepository = deviceSessionRepository
        self.executionHandler = executionHandler
    }
#else
    public init(
        port: UInt16 = 5894,
        serviceType: String = "_handshake._tcp",
        hostIdentity: CryptoIdentity,
        trustStore: TrustStore,
        sequenceCounter: SequenceCounter = SequenceCounter(),
        commandLogRepository: CommandLogRepository? = nil,
        pairingEventRepository: PairingEventRepository? = nil,
        deviceSessionRepository: DeviceSessionRepository? = nil,
        executionHandler: @escaping CommandExecutionHandler
    ) {
        self.port = port
        self.serviceType = serviceType
        self.hostIdentity = hostIdentity
        self.trustStore = trustStore
        self.initialSequenceCounter = sequenceCounter
        self.commandLogRepository = commandLogRepository
        self.pairingEventRepository = pairingEventRepository
        self.deviceSessionRepository = deviceSessionRepository
        self.executionHandler = executionHandler
    }
#endif

    // MARK: - Lifecycle

    /// Starts the local Bonjour advertisement and TCP listener.
    public func start() throws {
        guard !running else { throw ServerError.alreadyRunning }

        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = false
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.prohibitedInterfaceTypes = [.cellular]
            params.allowLocalEndpointReuse = true

            let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(integerLiteral: 5894)
            let newListener = try NWListener(using: params, on: nwPort)

            // Bonjour service advertisement with descriptive metadata
            var txtRecord = NWTXTRecord()
            txtRecord["v"] = "1"
            txtRecord["id"] = hostIdentity.identity.id.uuidString
            txtRecord["pk"] = hostIdentity.identity.shortFingerprint

            newListener.service = NWListener.Service(
                name: hostIdentity.identity.displayName,
                type: serviceType,
                txtRecord: txtRecord
            )

            newListener.newConnectionHandler = { [weak self] connection in
                let now = ISO8601DateFormatter().string(from: Date())
                print("[\(now)][HandshakePairing][Server] NEW INCOMING TCP CONNECTION from: \(connection.endpoint)")
                Task { [weak self] in
                    await self?.handleIncomingConnection(connection)
                }
            }

            newListener.stateUpdateHandler = { state in
                let now = ISO8601DateFormatter().string(from: Date())
                switch state {
                case .ready:
                    let boundPort = newListener.port?.rawValue ?? 0
                    print("[\(now)][HandshakePairing][Server] NWListener is READY on port \(boundPort) (service: \(self.serviceType), name: \(self.hostIdentity.identity.displayName))")
                case .failed(let error):
                    print("[\(now)][HandshakePairing][Server] NWListener FAILED: \(error.localizedDescription) (error: \(error))")
                case .waiting(let error):
                    print("[\(now)][HandshakePairing][Server] NWListener WAITING: \(error.localizedDescription) (error: \(error))")
                default:
                    print("[\(now)][HandshakePairing][Server] NWListener state: \(state)")
                }
            }

            let queue = DispatchQueue(label: "com.handshake.server.listener", qos: .userInitiated)
            newListener.start(queue: queue)

            self.listener = newListener
            self.running = true
        } catch {
            throw ServerError.listenerCreationFailed(error.localizedDescription)
        }
    }

    /// Registers an active pairing session on the host Mac to accept incoming pairing requests.
    public func setActivePairingSession(
        _ session: HostPairingSession?,
        approvalHandler: PairingApprovalHandler? = nil
    ) {
        let now = ISO8601DateFormatter().string(from: Date())
        if let s = session {
            print("[\(now)][HandshakePairing][Server] Active pairing session registered: id=\(s.invitation.id), hostAddress=\(s.invitation.hostAddress ?? "nil"), port=\(s.invitation.localPort), expires=\(s.invitation.expiresAt)")
        } else {
            print("[\(now)][HandshakePairing][Server] Active pairing session cleared.")
        }
        self.activePairingSession = session
        self.pairingApprovalHandler = approvalHandler
    }

    /// Stops the local listener and releases all networking resources.
    public func stop() {
        guard running else { return }
        listener?.cancel()
        listener = nil
        running = false
        activePairingSession = nil
        pairingApprovalHandler = nil
        peerSequenceCounters.removeAll()
        recentSessionIds.removeAll()
        recentCommandIds.removeAll()
        initialCounterAssigned = false
    }

    private func validateAndRecordSessionId(_ id: UUID) -> Bool {
        recentSessionIds.insertIfFresh(id)
    }

    private func validateAndRecordCommandId(_ id: UUID) -> Bool {
        recentCommandIds.insertIfFresh(id)
    }

    private func counter(for peerPublicKeyHex: String) -> SequenceCounter {
        if let existing = peerSequenceCounters[peerPublicKeyHex] {
            return existing
        }
        if !initialCounterAssigned {
            initialCounterAssigned = true
            peerSequenceCounters[peerPublicKeyHex] = initialSequenceCounter
            return initialSequenceCounter
        }
        let freshCounter = SequenceCounter()
        peerSequenceCounters[peerPublicKeyHex] = freshCounter
        return freshCounter
    }

    public var isRunning: Bool {
        return running
    }

    private func requestMacApproval(for client: DeviceIdentity, sasCode: String) async -> Bool {
        if let handler = self.pairingApprovalHandler {
            return await handler(client, sasCode)
        }
        return true
    }

    // MARK: - Inbound Connection Processing

    private func handleIncomingConnection(_ connection: NWConnection) {
        let now = ISO8601DateFormatter().string(from: Date())
        print("[\(now)][HandshakePairing][Server] Starting incoming connection from \(connection.endpoint)")
        connection.stateUpdateHandler = { state in
            let ts = ISO8601DateFormatter().string(from: Date())
            switch state {
            case .ready:
                print("[\(ts)][HandshakePairing][Server] Inbound connection READY from \(connection.endpoint)")
            case .failed(let err):
                print("[\(ts)][HandshakePairing][Server] Inbound connection FAILED: \(err.localizedDescription) (error: \(err))")
            case .waiting(let err):
                print("[\(ts)][HandshakePairing][Server] Inbound connection WAITING: \(err.localizedDescription) (error: \(err))")
            case .cancelled:
                print("[\(ts)][HandshakePairing][Server] Inbound connection CANCELLED")
            default:
                print("[\(ts)][HandshakePairing][Server] Inbound connection state: \(state)")
            }
        }
        connection.pathUpdateHandler = { path in
            let ts = ISO8601DateFormatter().string(from: Date())
            let ifaces = path.availableInterfaces.map { "\($0.name)(\($0.type))" }.joined(separator: ", ")
            print("[\(ts)][HandshakePairing][Server] Inbound connection path: status=\(path.status), interfaces=[\(ifaces)], isExpensive=\(path.isExpensive)")
        }

        let queue = DispatchQueue(label: "com.handshake.server.connection.\(UUID().uuidString)", qos: .userInitiated)
        connection.start(queue: queue)

        Task {
            var activeSessionDbId: Int64? = nil
            var activeSession: EstablishedSession? = nil
            defer {
                if let sessionDbId = activeSessionDbId {
                    try? self.deviceSessionRepository?.endSession(
                        id: sessionDbId,
                        endedAt: DatabaseManager.iso8601String(),
                        status: "closed"
                    )
                }
                if let session = activeSession {
                    _ = try? self.pairingEventRepository?.insert(PairingEventRecord(
                        peerDeviceId: session.peer.id.uuidString,
                        peerDeviceName: session.peer.displayName,
                        eventType: "device_disconnected",
                        result: "closed"
                    ))
                }
                connection.cancel()
            }

            while true {
                do {
                    // 1. Read framed envelope or session handshake packet
                    let rawData: Data
                    do {
                        rawData = try await NetworkFraming.receive(from: connection)
                    } catch NetworkFraming.FramingError.connectionClosed {
                        print("[\(ISO8601DateFormatter().string(from: Date()))][HandshakePairing][Server] Client closed connection.")
                        break // Clean disconnect from client
                    }

                    // Check if incoming frame is a PairingRequest
                    if let pairingRequest = try? JSONDecoder().decode(PairingRequest.self, from: rawData) {
                        let ts = ISO8601DateFormatter().string(from: Date())
                        print("[\(ts)][HandshakePairing][Server][\(pairingRequest.invitationId)] PAIRING REQUEST RECEIVED from \(pairingRequest.clientIdentity.displayName) (UUID: \(pairingRequest.clientIdentity.id))")
                        _ = try? self.pairingEventRepository?.insert(PairingEventRecord(
                            peerDeviceId: pairingRequest.clientIdentity.id.uuidString,
                            peerDeviceName: pairingRequest.clientIdentity.displayName,
                            eventType: "pairing_requested",
                            result: "received"
                        ))

                        guard let hostSession = self.activePairingSession else {
                            print("[\(ts)][HandshakePairing][Server][\(pairingRequest.invitationId)] REJECTING: No active pairing session on Mac!")
                            try await sendRejection(
                                commandId: pairingRequest.invitationId,
                                peerDeviceId: pairingRequest.clientIdentity.id.uuidString,
                                peerDeviceName: pairingRequest.clientIdentity.displayName,
                                commandType: "PAIRING_REQUEST",
                                reason: "No active pairing session on Mac. Open pairing screen on Mac.",
                                over: connection
                            )
                            _ = try? self.pairingEventRepository?.insert(PairingEventRecord(
                                peerDeviceId: pairingRequest.clientIdentity.id.uuidString,
                                peerDeviceName: pairingRequest.clientIdentity.displayName,
                                eventType: "pairing_rejected",
                                result: "failed"
                            ))
                            break
                        }

                        do {
                            let (response, derivedSAS) = try await hostSession.processRequest(pairingRequest)
                            _ = try? self.pairingEventRepository?.insert(PairingEventRecord(
                                peerDeviceId: pairingRequest.clientIdentity.id.uuidString,
                                peerDeviceName: pairingRequest.clientIdentity.displayName,
                                eventType: "qr_invitation_validated",
                                result: "success"
                            ))

                            // 1. Send PairingResponse to client so iPhone can derive SAS and present UI immediately
                            let respData = try JSONEncoder().encode(response)
                            try await NetworkFraming.send(data: respData, over: connection)

                            // 2. Request Mac user explicit bilateral confirmation over the derived SAS concurrently
                            // This guarantees both iPhone and Mac display the identical 6-digit SAS code at the exact same time
                            async let macApprovalTask = self.requestMacApproval(for: pairingRequest.clientIdentity, sasCode: derivedSAS)

                            // 3. Await confirmation from client with bounded timeout (60 seconds)
                            let confirmData = try await NetworkFraming.receive(from: connection, timeoutSeconds: 60.0)
                            let confirmation = try JSONDecoder().decode(PairingConfirmation.self, from: confirmData)
                            guard confirmation.isApproved else {
                                let failedComp = PairingCompletion(
                                    invitationId: pairingRequest.invitationId,
                                    isSuccessful: false,
                                    hostApprovalSignatureHex: ""
                                )
                                if let compData = try? JSONEncoder().encode(failedComp) {
                                    try? await NetworkFraming.send(data: compData, over: connection)
                                }
                                self.activePairingSession = nil
                                self.pairingApprovalHandler = nil
                                _ = try? self.pairingEventRepository?.insert(PairingEventRecord(
                                    peerDeviceId: pairingRequest.clientIdentity.id.uuidString,
                                    peerDeviceName: pairingRequest.clientIdentity.displayName,
                                    eventType: "pairing_rejected_by_client",
                                    result: "failed"
                                ))
                                break
                            }

                            // 4. Await Mac user confirmation
                            let macApproved = await macApprovalTask
                            guard macApproved else {
                                let failedComp = PairingCompletion(
                                    invitationId: pairingRequest.invitationId,
                                    isSuccessful: false,
                                    hostApprovalSignatureHex: ""
                                )
                                if let compData = try? JSONEncoder().encode(failedComp) {
                                    try? await NetworkFraming.send(data: compData, over: connection)
                                }
                                self.activePairingSession = nil
                                self.pairingApprovalHandler = nil
                                _ = try? self.pairingEventRepository?.insert(PairingEventRecord(
                                    peerDeviceId: pairingRequest.clientIdentity.id.uuidString,
                                    peerDeviceName: pairingRequest.clientIdentity.displayName,
                                    eventType: "pairing_rejected_by_host",
                                    result: "failed"
                                ))
                                break
                            }

                            _ = try? self.pairingEventRepository?.insert(PairingEventRecord(
                                peerDeviceId: pairingRequest.clientIdentity.id.uuidString,
                                peerDeviceName: pairingRequest.clientIdentity.displayName,
                                eventType: "sas_confirmed",
                                result: "success"
                            ))

                            // 5. Complete mutual pairing and pin client in TrustStore
                            let (completion, _) = try await hostSession.processConfirmation(confirmation, trustStore: self.trustStore)
                            let compData = try JSONEncoder().encode(completion)
                            try await NetworkFraming.send(data: compData, over: connection)
                            self.activePairingSession = nil
                            self.pairingApprovalHandler = nil
                            _ = try? self.pairingEventRepository?.insert(PairingEventRecord(
                                peerDeviceId: pairingRequest.clientIdentity.id.uuidString,
                                peerDeviceName: pairingRequest.clientIdentity.displayName,
                                eventType: "pairing_completed",
                                result: "success"
                            ))
                            break
                        } catch {
                            let failedComp = PairingCompletion(
                                invitationId: pairingRequest.invitationId,
                                isSuccessful: false,
                                hostApprovalSignatureHex: ""
                            )
                            if let compData = try? JSONEncoder().encode(failedComp) {
                                try? await NetworkFraming.send(data: compData, over: connection)
                            }
                            self.activePairingSession = nil
                            self.pairingApprovalHandler = nil
                            _ = try? self.pairingEventRepository?.insert(PairingEventRecord(
                                peerDeviceId: pairingRequest.clientIdentity.id.uuidString,
                                peerDeviceName: pairingRequest.clientIdentity.displayName,
                                eventType: "pairing_failed",
                                result: error.localizedDescription
                            ))
                            break
                        }
                    }

                    // Check if incoming frame is a fresh SessionInitiation handshake
                    if let sessionInit = try? JSONDecoder().decode(SessionInitiation.self, from: rawData) {
                        // If this connection already had an active session, cleanly mark it superseded
                        if let oldSessionDbId = activeSessionDbId {
                            try? self.deviceSessionRepository?.endSession(
                                id: oldSessionDbId,
                                endedAt: DatabaseManager.iso8601String(),
                                status: "superseded"
                            )
                            activeSessionDbId = nil
                            activeSession = nil
                        }

                        // 1a. Validate clock skew
                        guard HandshakeTime.isTimestampValid(sessionInit.timestampMilliseconds) else {
                            try await sendRejection(
                                commandId: sessionInit.id,
                                peerDeviceId: sessionInit.clientIdentity.id.uuidString,
                                peerDeviceName: sessionInit.clientIdentity.displayName,
                                commandType: "SESSION_INIT",
                                reason: "Session initiation failed: clock skew exceeded.",
                                over: connection
                            )
                            break
                        }

                        // 1b. Validate anti-replay on sessionId
                        guard self.validateAndRecordSessionId(sessionInit.id) else {
                            try await sendRejection(
                                commandId: sessionInit.id,
                                peerDeviceId: sessionInit.clientIdentity.id.uuidString,
                                peerDeviceName: sessionInit.clientIdentity.displayName,
                                commandType: "SESSION_INIT",
                                reason: "Session initiation failed: replayed session identifier.",
                                over: connection
                            )
                            break
                        }

                        // 1c. Validate client identity in TrustStore
                        guard let trustRecord = await trustStore.getRecord(publicKeyHex: sessionInit.clientIdentity.publicKeyHex) else {
                            try await sendRejection(
                                commandId: sessionInit.id,
                                peerDeviceId: sessionInit.clientIdentity.id.uuidString,
                                peerDeviceName: sessionInit.clientIdentity.displayName,
                                commandType: "SESSION_INIT",
                                reason: "Device is not paired or recognized.",
                                over: connection
                            )
                            break
                        }

                        guard !trustRecord.isRevoked else {
                            try await sendRejection(
                                commandId: sessionInit.id,
                                peerDeviceId: trustRecord.peer.id.uuidString,
                                peerDeviceName: trustRecord.peer.displayName,
                                commandType: "SESSION_INIT",
                                reason: "Device trust has been revoked.",
                                over: connection
                            )
                            break
                        }

                        // 1d. Verify client digital signature over sessionInit
                        guard let clientSigData = Data(hexString: sessionInit.signatureHex),
                              CryptoIdentity.verify(
                                signatureRaw: clientSigData,
                                for: sessionInit.signablePayload,
                                publicKeyHex: trustRecord.peer.publicKeyHex
                              ) else {
                            try await sendRejection(
                                commandId: sessionInit.id,
                                peerDeviceId: trustRecord.peer.id.uuidString,
                                peerDeviceName: trustRecord.peer.displayName,
                                commandType: "SESSION_INIT",
                                reason: "Session initiation failed: invalid client cryptographic signature.",
                                over: connection
                            )
                            break
                        }

                        // 1e. Generate fresh host ephemeral P-256 key pair
                        let hostEphemeral = EphemeralKeyExchange()
                        let responsePlaceholder = SessionResponse(
                            id: sessionInit.id,
                            hostIdentity: self.hostIdentity.identity,
                            hostEphemeralPublicKeyHex: hostEphemeral.publicKeyHex
                        )
                        let hostSig = try self.hostIdentity.sign(data: responsePlaceholder.signablePayload)
                        let sessionResponse = SessionResponse(
                            id: sessionInit.id,
                            timestampMilliseconds: responsePlaceholder.timestampMilliseconds,
                            hostIdentity: self.hostIdentity.identity,
                            hostEphemeralPublicKeyHex: hostEphemeral.publicKeyHex,
                            signatureHex: hostSig.hexString
                        )

                        // 1f. Transmit framed SessionResponse to client
                        let respData = try JSONEncoder().encode(sessionResponse)
                        try await NetworkFraming.send(data: respData, over: connection)

                        // 1g. Derive fresh session keys & deterministic nonce salts bound to master PSK
                        let sharedSecret = try hostEphemeral.computeSharedSecret(peerEphemeralPublicKeyHex: sessionInit.clientEphemeralPublicKeyHex)
                        let transcript = sessionInit.signablePayload + sessionResponse.signablePayload
                        let masterPSK = await trustStore.retrievePreSharedKey(forPeerId: trustRecord.id)

                        let keys = SessionKeyDerivation.deriveKeys(
                            sharedSecret: sharedSecret,
                            sessionId: sessionInit.id,
                            transcript: transcript,
                            masterPSK: masterPSK
                        )

                        activeSession = EstablishedSession(
                            sessionId: sessionInit.id,
                            peer: trustRecord.peer,
                            clientToHostKey: keys.clientToHostKey,
                            hostToClientKey: keys.hostToClientKey,
                            clientToHostNonceSalt: keys.clientNonceSalt,
                            hostToClientNonceSalt: keys.hostNonceSalt
                        )

                        // Audit device session start
                        let sessionRecord = DeviceSessionRecord(
                            peerDeviceId: trustRecord.peer.id.uuidString,
                            sessionStartedAt: DatabaseManager.iso8601String(),
                            status: "active"
                        )
                        activeSessionDbId = try? self.deviceSessionRepository?.insert(sessionRecord)
                        _ = try? self.pairingEventRepository?.insert(PairingEventRecord(
                            peerDeviceId: trustRecord.peer.id.uuidString,
                            peerDeviceName: trustRecord.peer.displayName,
                            eventType: "device_connected",
                            result: "success"
                        ))

                        continue
                    }

                    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: rawData)

                    // 2. Validate sender against Trust Store
                    guard let trustRecord = await trustStore.getRecord(publicKeyHex: envelope.senderPublicKeyHex) else {
                        try await sendRejection(
                            commandId: envelope.id,
                            peerDeviceId: "unknown",
                            peerDeviceName: nil,
                            commandType: "UNKNOWN",
                            reason: "Device is not paired or recognized.",
                            over: connection
                        )
                        break
                    }

                    guard !trustRecord.isRevoked else {
                        try await sendRejection(
                            commandId: envelope.id,
                            peerDeviceId: trustRecord.peer.id.uuidString,
                            peerDeviceName: trustRecord.peer.displayName,
                            commandType: "UNKNOWN",
                            reason: "Device trust has been revoked.",
                            over: connection
                        )
                        break
                    }

                    // 3. Authenticate and decrypt envelope with fresh session key (or direct pre-shared key)
                    let sessionKey: SymmetricKey
                    let expectedNonceSalt: Data?
                    let sequenceCounter: SequenceCounter

                    if let session = activeSession {
                        guard !session.isExpired() else {
                            try await sendRejection(
                                commandId: envelope.id,
                                peerDeviceId: session.peer.id.uuidString,
                                peerDeviceName: session.peer.displayName,
                                commandType: "UNKNOWN",
                                reason: "Session expired. Please reconnect.",
                                over: connection
                            )
                            break
                        }
                        guard envelope.senderPublicKeyHex.lowercased() == session.peer.publicKeyHex.lowercased() else {
                            try await sendRejection(
                                commandId: envelope.id,
                                peerDeviceId: session.peer.id.uuidString,
                                peerDeviceName: session.peer.displayName,
                                commandType: "UNKNOWN",
                                reason: "Sender does not match active session peer.",
                                over: connection
                            )
                            break
                        }
                        sessionKey = session.clientToHostKey
                        expectedNonceSalt = session.clientToHostNonceSalt
                        sequenceCounter = session.incomingSequenceCounter
                    } else {
                        let masterPSK = await trustStore.retrievePreSharedKey(forPeerId: trustRecord.id)
                        let pskHex = masterPSK?.withUnsafeBytes { Data($0).hexString } ?? trustRecord.preSharedKeyHex
                        do {
                            sessionKey = try SecureChannel.resolveSessionKey(
                                preSharedKeyHex: pskHex,
                                role: .clientToHost
                            )
                        } catch {
                            try await sendRejection(
                                commandId: envelope.id,
                                peerDeviceId: trustRecord.peer.id.uuidString,
                                peerDeviceName: trustRecord.peer.displayName,
                                commandType: "UNKNOWN",
                                reason: "Authentication failed: Missing or invalid pre-shared key.",
                                over: connection
                            )
                            break
                        }
                        expectedNonceSalt = nil
                        sequenceCounter = self.counter(for: trustRecord.peer.publicKeyHex)
                    }

                    let message: CommandMessage
                    do {
                        message = try await SecureChannel.open(
                            envelope: envelope,
                            sessionKey: sessionKey,
                            trustedSenderPublicKeyHex: trustRecord.peer.publicKeyHex,
                            sequenceCounter: sequenceCounter,
                            expectedNonceSalt: expectedNonceSalt
                        )
                    } catch {
                        try await sendRejection(
                            commandId: envelope.id,
                            peerDeviceId: trustRecord.peer.id.uuidString,
                            peerDeviceName: trustRecord.peer.displayName,
                            commandType: "ENCRYPTED_COMMAND",
                            reason: "Authentication failed: \(error.localizedDescription)",
                            over: connection
                        )
                        break
                    }

                    // 3b. Anti-replay and deduplication check on CommandMessage.id
                    guard self.validateAndRecordCommandId(message.id) else {
                        try await sendRejection(
                            commandId: message.id,
                            peerDeviceId: trustRecord.peer.id.uuidString,
                            peerDeviceName: trustRecord.peer.displayName,
                            commandType: message.command.rawValue,
                            reason: "Duplicate command request ID rejected.",
                            over: connection
                        )
                        continue
                    }

                    // 4. Verify command type is authorized in trust record
                    guard trustRecord.authorizedCapabilities.contains(message.command) else {
                        try await sendRejection(
                            commandId: message.id,
                            peerDeviceId: trustRecord.peer.id.uuidString,
                            peerDeviceName: trustRecord.peer.displayName,
                            commandType: message.command.rawValue,
                            reason: "Command \(message.command.displayName) not authorized for this device.",
                            over: connection
                        )
                        continue
                    }

                    // 5. Update last seen timestamp & record command receipt
                    try? await trustStore.updateLastSeen(id: trustRecord.id)

                    let receivedAt = DatabaseManager.iso8601String()
                    _ = try? commandLogRepository?.insert(CommandLogRecord(
                        requestId: message.id.uuidString,
                        peerDeviceId: trustRecord.peer.id.uuidString,
                        peerDeviceName: trustRecord.peer.displayName,
                        commandType: message.command.rawValue,
                        receivedAt: receivedAt,
                        status: "received",
                        protocolVersion: "1.0"
                    ))

                    // Mark execution started in audit log
                    let startedAt = DatabaseManager.iso8601String()
                    try? commandLogRepository?.markExecutionStarted(
                        requestId: message.id.uuidString,
                        startedAt: startedAt
                    )

                    // 6. Execute authorized command on host Mac
                    let status = await executionHandler(message, trustRecord.peer)

                    // Record completion status in audit log
                    let completedAt = DatabaseManager.iso8601String()
                    let statusStr: String
                    let resultCode: String?
                    let errorMsg: String?
                    switch status {
                    case .executed:
                        statusStr = "executed"
                        resultCode = "SUCCESS"
                        errorMsg = nil
                    case .accepted:
                        statusStr = "accepted"
                        resultCode = "ACCEPTED"
                        errorMsg = nil
                    case .authenticated:
                        statusStr = "authenticated"
                        resultCode = "PENDING"
                        errorMsg = nil
                    case .authorized:
                        statusStr = "authorized"
                        resultCode = "PENDING"
                        errorMsg = nil
                    case .sleepRequestIssued:
                        statusStr = "sleep_request_issued"
                        resultCode = "SLEEP_REQUEST_ISSUED"
                        errorMsg = nil
                    case .physicalSleepObserved:
                        statusStr = "physical_sleep_observed"
                        resultCode = "PHYSICAL_SLEEP_OBSERVED"
                        errorMsg = nil
                    case .failed(let reason):
                        statusStr = "failed"
                        resultCode = "FAILED"
                        errorMsg = reason
                    case .rejected(let reason):
                        statusStr = "rejected"
                        resultCode = "REJECTED"
                        errorMsg = reason
                    case .received:
                        statusStr = "received"
                        resultCode = "PENDING"
                        errorMsg = nil
                    }

                    try? commandLogRepository?.updateCompletion(
                        requestId: message.id.uuidString,
                        status: statusStr,
                        completedAt: completedAt,
                        resultCode: resultCode,
                        errorMessage: errorMsg
                    )

                    // 7. Send signed acknowledgment
                    let ack = try makeAcknowledgment(commandId: message.id, status: status)
                    let ackData = try JSONEncoder().encode(ack)
                    try await NetworkFraming.send(data: ackData, over: connection)

                    // 8. Orderly two-stage sleep processing:
                    // Guarantee the client receives acknowledgment before sleep enters power-down
                    if message.command == .sleep, case .accepted = status {
                        #if os(macOS)
                        await awaitReceiptAndSleep(
                            over: connection,
                            expectedCommandId: message.id,
                            expectedClient: trustRecord.peer
                        )
                        #endif
                        break
                    }

                } catch {
                    // Connection error or malformed frame: fail closed and terminate connection
                    break
                }
            }
        }
    }

    #if os(macOS)
    /// Two-stage sleep handshake: awaits client's signed CommandReceipt confirmation
    /// with a bounded 2.0-second fallback timeout before invoking IOPMSleepSystem.
    private func awaitReceiptAndSleep(
        over connection: NWConnection,
        expectedCommandId: UUID,
        expectedClient: DeviceIdentity
    ) async {
        await withTaskGroup(of: Void.self) { group in
            // Stage 1: Await signed confirmation receipt from iPhone
            group.addTask {
                do {
                    let receiptBytes = try await NetworkFraming.receive(from: connection)
                    let receipt = try JSONDecoder().decode(CommandReceipt.self, from: receiptBytes)
                    guard receipt.commandId == expectedCommandId else { return }
                    guard let sigData = Data(hexString: receipt.signatureHex),
                          CryptoIdentity.verify(
                            signatureRaw: sigData,
                            for: receipt.signablePayload,
                            publicKeyHex: expectedClient.publicKeyHex
                          ) else {
                        return
                    }
                    // Verified receipt received! Short pause to allow clean TCP FIN transmission
                    try? await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    // Receipt timeout or connection closure: proceed to fallback timeout
                }
            }

            // Stage 2: Bounded 2.0s fallback timeout
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            // Wait for receipt confirmation or timeout expiration
            _ = await group.next()
            group.cancelAll()
        }

        let result = sleepEngine.triggerSleep()
        let completedAt = DatabaseManager.iso8601String()
        switch result {
        case .sleepInitiated:
            try? commandLogRepository?.updateCompletion(
                requestId: expectedCommandId.uuidString,
                status: "sleep_request_issued",
                completedAt: completedAt,
                resultCode: "SLEEP_REQUEST_ISSUED",
                errorMessage: nil
            )
        case .failed(let reason):
            try? commandLogRepository?.updateCompletion(
                requestId: expectedCommandId.uuidString,
                status: "failed",
                completedAt: completedAt,
                resultCode: "FAILED",
                errorMessage: reason
            )
        case .sleepNotSupported:
            try? commandLogRepository?.updateCompletion(
                requestId: expectedCommandId.uuidString,
                status: "failed",
                completedAt: completedAt,
                resultCode: "UNSUPPORTED",
                errorMessage: "System sleep is not supported on this Mac"
            )
        default:
            break
        }
    }
    #endif

    private func sendRejection(
        commandId: UUID,
        peerDeviceId: String = "unknown",
        peerDeviceName: String? = nil,
        commandType: String = "unknown",
        reason: String,
        over connection: NWConnection
    ) async throws {
        _ = try? commandLogRepository?.insert(CommandLogRecord(
            requestId: commandId.uuidString,
            peerDeviceId: peerDeviceId,
            peerDeviceName: peerDeviceName,
            commandType: commandType,
            status: "rejected",
            resultCode: "REJECTED",
            errorMessage: reason
        ))
        let ack = try makeAcknowledgment(commandId: commandId, status: .rejected(reason))
        let ackData = try JSONEncoder().encode(ack)
        try await NetworkFraming.send(data: ackData, over: connection)
    }

    private func makeAcknowledgment(
        commandId: UUID,
        status: CommandAcknowledgment.ExecutionStatus
    ) throws -> CommandAcknowledgment {
        let placeholder = CommandAcknowledgment(
            commandId: commandId,
            status: status,
            hostIdentity: hostIdentity.identity
        )
        let signature = try hostIdentity.sign(data: placeholder.signablePayload)
        return CommandAcknowledgment(
            commandId: commandId,
            status: status,
            timestampMilliseconds: placeholder.timestampMilliseconds,
            hostIdentity: hostIdentity.identity,
            signatureHex: signature.hexString
        )
    }
}
