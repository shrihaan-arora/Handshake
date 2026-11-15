import Foundation
import Network
import CryptoKit

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
    private var recentSessionIds: Set<UUID> = []
    private var recentCommandIds: Set<UUID> = []
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
                Task { [weak self] in
                    await self?.handleIncomingConnection(connection)
                }
            }

            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    break
                case .failed(let error):
                    print("HandshakeServer listener failed: \(error)")
                default:
                    break
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
        if recentSessionIds.contains(id) {
            return false
        }
        recentSessionIds.insert(id)
        if recentSessionIds.count > 1000 {
            recentSessionIds.removeFirst()
        }
        return true
    }

    private func validateAndRecordCommandId(_ id: UUID) -> Bool {
        if recentCommandIds.contains(id) {
            return false
        }
        recentCommandIds.insert(id)
        if recentCommandIds.count > 2000 {
            recentCommandIds.removeFirst()
        }
        return true
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
                        break // Clean disconnect from client
                    }

                    // Check if incoming frame is a PairingRequest
                    if let pairingRequest = try? JSONDecoder().decode(PairingRequest.self, from: rawData) {
                        _ = try? self.pairingEventRepository?.insert(PairingEventRecord(
                            peerDeviceId: pairingRequest.clientIdentity.id.uuidString,
                            peerDeviceName: pairingRequest.clientIdentity.displayName,
                            eventType: "pairing_requested",
                            result: "received"
                        ))

                        guard let hostSession = self.activePairingSession else {
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
                    if activeSession == nil, let sessionInit = try? JSONDecoder().decode(SessionInitiation.self, from: rawData) {
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

                    // 3. Authenticate and decrypt envelope with fresh session key (or fallback)
                    let sessionKey: SymmetricKey
                    let expectedNonceSalt: Data?

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
                    } else {
                        let masterPSK = await trustStore.retrievePreSharedKey(forPeerId: trustRecord.id)
                        let pskHex = masterPSK?.withUnsafeBytes { Data($0).hexString } ?? trustRecord.preSharedKeyHex
                        sessionKey = SecureChannel.resolveSessionKey(
                            preSharedKeyHex: pskHex,
                            fallbackPublicKeyHex: envelope.senderPublicKeyHex,
                            role: .clientToHost
                        )
                        expectedNonceSalt = nil
                    }

                    let peerCounter = self.counter(for: trustRecord.peer.publicKeyHex)
                    let message: CommandMessage
                    do {
                        message = try await SecureChannel.open(
                            envelope: envelope,
                            sessionKey: sessionKey,
                            trustedSenderPublicKeyHex: trustRecord.peer.publicKeyHex,
                            sequenceCounter: peerCounter,
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
                    if message.command == .sleep, case .executed = status {
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

        _ = sleepEngine.triggerSleep()
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
