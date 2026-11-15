import Foundation
import Network
import CryptoKit

/// Local peer-to-peer TCP client for the iPhone application.
/// Connects to a paired Mac companion on demand, issues signed command envelopes,
/// awaits verified cryptographic acknowledgments, and terminates immediately.
public final class HandshakeClient: Sendable {

    public enum ClientError: Error, LocalizedError, Equatable {
        case macNotFound
        case connectionFailed(String)
        case timeout
        case invalidAcknowledgment
        case commandRejected(String)
        case executionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .macNotFound:
                return "Mac companion was not discovered on local network. Ensure Handshake is open on the Mac."
            case .connectionFailed(let msg):
                return "Connection failed: \(msg)"
            case .timeout:
                return "Command execution timed out."
            case .invalidAcknowledgment:
                return "Mac response failed signature verification."
            case .commandRejected(let reason):
                return "Mac rejected command: \(reason)"
            case .executionFailed(let reason):
                return "Mac failed to execute command: \(reason)"
            }
        }
    }

    private let clientIdentity: CryptoIdentity
    private let sequenceCounter: SequenceCounter

    public init(
        clientIdentity: CryptoIdentity,
        sequenceCounter: SequenceCounter = SequenceCounter()
    ) {
        self.clientIdentity = clientIdentity
        self.sequenceCounter = sequenceCounter
    }

    // MARK: - Discovery

    /// Scans the local network for an active Handshake Mac companion advertising via Bonjour.
    /// Filters results to identify the target paired Mac by UUID, public key fingerprint, or localized name.
    public func discoverMac(
        serviceType: String = "_handshake._tcp",
        targetPeer: DeviceIdentity? = nil,
        timeoutSeconds: TimeInterval = 8.0,
        onStateChange: (@Sendable (ConnectionState) -> Void)? = nil
    ) async throws -> (endpoint: NWEndpoint, discoveredName: String) {
        onStateChange?(.discovering)

        let browserParams = NWParameters()
        browserParams.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: browserParams)

        return try await withCheckedThrowingContinuation { continuation in
            let resumeState = ResumeLock()
            let queue = DispatchQueue(label: "com.handshake.client.discovery", qos: .userInitiated)

            // Setup bounded timeout timer
            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                if resumeState.takeResume() {
                    browser.cancel()
                    onStateChange?(.macUnavailable(reason: "Mac companion not found on local network. Ensure Handshake is open on the Mac."))
                    continuation.resume(throwing: ClientError.macNotFound)
                }
            }

            browser.browseResultsChangedHandler = { results, _ in
                guard !results.isEmpty else { return }

                for result in results {
                    var isMatch = false
                    var matchedName = "MacBook"

                    if case .service(let name, _, _, _) = result.endpoint {
                        matchedName = name
                    }

                    if let target = targetPeer {
                        // Check TXT metadata first
                        if case .bonjour(let txt) = result.metadata {
                            if let id = txt["id"], id == target.id.uuidString {
                                isMatch = true
                            } else if let fp = txt["pk"], fp == target.shortFingerprint {
                                isMatch = true
                            }
                        }

                        // Robust normalized name matching
                        if !isMatch {
                            let cleanMatched = NetworkHelper.normalizeServiceName(matchedName)
                            let cleanTarget = NetworkHelper.normalizeServiceName(target.displayName)

                            if cleanMatched.caseInsensitiveCompare(cleanTarget) == .orderedSame ||
                               cleanMatched.localizedCaseInsensitiveContains(cleanTarget) ||
                               cleanTarget.localizedCaseInsensitiveContains(cleanMatched) {
                                isMatch = true
                            }
                        }

                        // Single active Handshake service fallback
                        if !isMatch && results.count == 1 {
                            isMatch = true
                        }
                    } else {
                        // No specific target peer requested; accept first available Handshake service
                        isMatch = true
                    }

                    if isMatch {
                        if resumeState.takeResume() {
                            browser.cancel()
                            onStateChange?(.macFound(peerName: matchedName))
                            continuation.resume(returning: (result.endpoint, matchedName))
                            return
                        }
                    }
                }
            }

            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    if resumeState.takeResume() {
                        browser.cancel()
                        onStateChange?(.macUnavailable(reason: error.localizedDescription))
                        continuation.resume(throwing: ClientError.connectionFailed(error.localizedDescription))
                    }
                }
            }

            browser.start(queue: queue)
        }
    }

    /// Backward-compatible discoverMac overload returning NWEndpoint directly.
    public func discoverMac(
        serviceType: String = "_handshake._tcp",
        timeoutSeconds: TimeInterval = 3.5
    ) async throws -> NWEndpoint {
        let (endpoint, _) = try await discoverMac(
            serviceType: serviceType,
            targetPeer: nil,
            timeoutSeconds: timeoutSeconds,
            onStateChange: nil
        )
        return endpoint
    }

    // MARK: - Mutual Pairing Protocol

    /// Executes bilateral pairing protocol with a host Mac following a scanned QR invitation.
    /// Connects over local network, exchanges ephemeral keys, derives SAS, awaits approval,
    /// and establishes a pinned TrustRecord in the provided TrustStore.
    public func pair(
        with invitation: PairingInvitation,
        trustStore: TrustStore,
        onSASDerived: @escaping @Sendable (String) async -> Bool
    ) async throws -> TrustRecord {
        guard !invitation.isExpired() else {
            throw PairingError.invitationExpired
        }

        // 1. Dual-path endpoint resolution (Direct host probe + Bonjour discovery fallback)
        var targetEndpoint: NWEndpoint? = nil

        if let host = invitation.hostAddress, !host.isEmpty,
           let nwPort = NWEndpoint.Port(rawValue: invitation.localPort) {
            let directEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
            let isReachable = await withCheckedContinuation { cont in
                let probeLock = ResumeLock()
                let probeQueue = DispatchQueue(label: "com.handshake.probe", qos: .userInitiated)
                let probeParams = NWParameters.tcp
                let probeConn = NWConnection(to: directEndpoint, using: probeParams)

                probeQueue.asyncAfter(deadline: .now() + 1.5) {
                    if probeLock.takeResume() {
                        probeConn.cancel()
                        cont.resume(returning: false)
                    }
                }
                probeConn.stateUpdateHandler = { state in
                    if state == .ready {
                        if probeLock.takeResume() {
                            probeConn.cancel()
                            cont.resume(returning: true)
                        }
                    } else if case .failed = state {
                        if probeLock.takeResume() {
                            probeConn.cancel()
                            cont.resume(returning: false)
                        }
                    }
                }
                probeConn.start(queue: probeQueue)
            }
            if isReachable {
                targetEndpoint = directEndpoint
            }
        }

        if targetEndpoint == nil {
            let (endpoint, _) = try await discoverMac(
                serviceType: "_handshake._tcp",
                targetPeer: invitation.hostIdentity,
                timeoutSeconds: 8.0
            )
            targetEndpoint = endpoint
        }

        guard let endpoint = targetEndpoint else {
            throw ClientError.macNotFound
        }

        // 2. Establish local TCP connection
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = false
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        let connection = NWConnection(to: endpoint, using: params)

        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "com.handshake.client.pairing", qos: .userInitiated)
            let resumeState = ResumeLock()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Task {
                        do {
                            // 3. Initialize ClientPairingSession
                            let clientSession = try ClientPairingSession(
                                invitation: invitation,
                                clientIdentity: self.clientIdentity
                            )

                            // 4. Send PairingRequest
                            let request = await clientSession.createRequest()
                            let reqData = try JSONEncoder().encode(request)
                            try await NetworkFraming.send(data: reqData, over: connection)

                            // 5. Receive PairingResponse
                            let respBytes = try await NetworkFraming.receive(from: connection)
                            let response = try JSONDecoder().decode(PairingResponse.self, from: respBytes)

                            // 6. Process response & derive SAS code independently
                            let sasCode = try await clientSession.processResponse(response)

                            // 7. Request user approval over derived SAS code
                            let approved = await onSASDerived(sasCode)
                            guard approved else {
                                let rejectConfirm = try await clientSession.createConfirmation(isApproved: false)
                                let rejectData = try JSONEncoder().encode(rejectConfirm)
                                try? await NetworkFraming.send(data: rejectData, over: connection)
                                connection.cancel()
                                if resumeState.takeResume() {
                                    continuation.resume(throwing: PairingError.unapproved)
                                }
                                return
                            }

                            // 8. Send approved PairingConfirmation
                            let confirmation = try await clientSession.createConfirmation(isApproved: true)
                            let confirmData = try JSONEncoder().encode(confirmation)
                            try await NetworkFraming.send(data: confirmData, over: connection)

                            // 9. Receive PairingCompletion
                            let compBytes = try await NetworkFraming.receive(from: connection)
                            let completion = try JSONDecoder().decode(PairingCompletion.self, from: compBytes)

                            // 10. Complete pairing and pin host in TrustStore
                            let establishedRecord = try await clientSession.completePairing(completion, trustStore: trustStore)

                            connection.cancel()
                            if resumeState.takeResume() {
                                continuation.resume(returning: establishedRecord)
                            }
                        } catch {
                            connection.cancel()
                            if resumeState.takeResume() {
                                continuation.resume(throwing: error)
                            }
                        }
                    }

                case .failed(let error):
                    if resumeState.takeResume() {
                        continuation.resume(throwing: ClientError.connectionFailed(error.localizedDescription))
                    }

                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    // MARK: - Command Dispatch

    /// Performs mutual ephemeral P-256 ECDH session handshake over an active NWConnection.
    public func performSessionHandshake(
        connection: NWConnection,
        trustedHostPublicKeyHex: String,
        masterPSK: SymmetricKey?
    ) async throws -> EstablishedSession {
        let clientEphemeral = EphemeralKeyExchange()
        let sessionId = UUID()
        let initPlaceholder = SessionInitiation(
            id: sessionId,
            clientIdentity: clientIdentity.identity,
            clientEphemeralPublicKeyHex: clientEphemeral.publicKeyHex
        )
        let sig = try clientIdentity.sign(data: initPlaceholder.signablePayload)
        let sessionInit = SessionInitiation(
            id: sessionId,
            timestampMilliseconds: initPlaceholder.timestampMilliseconds,
            clientIdentity: clientIdentity.identity,
            clientEphemeralPublicKeyHex: clientEphemeral.publicKeyHex,
            signatureHex: sig.hexString
        )

        // Send framed SessionInitiation
        let initData = try JSONEncoder().encode(sessionInit)
        try await NetworkFraming.send(data: initData, over: connection)

        // Receive framed SessionResponse
        let respBytes = try await NetworkFraming.receive(from: connection)

        // Check if server rejected handshake
        if let ack = try? JSONDecoder().decode(CommandAcknowledgment.self, from: respBytes) {
            if case .rejected(let reason) = ack.status {
                throw ClientError.commandRejected(reason)
            }
        }

        let sessionResponse = try JSONDecoder().decode(SessionResponse.self, from: respBytes)

        // Verify session ID match
        guard sessionResponse.id == sessionId else {
            throw ClientError.connectionFailed("Session handshake ID mismatch")
        }

        // Verify clock skew
        guard HandshakeTime.isTimestampValid(sessionResponse.timestampMilliseconds) else {
            throw ClientError.connectionFailed("Session response clock skew exceeded")
        }

        // Verify host identity matches trusted host public key
        guard sessionResponse.hostIdentity.publicKeyHex.lowercased() == trustedHostPublicKeyHex.lowercased() else {
            throw ClientError.connectionFailed("Session host public key does not match trusted peer")
        }

        // Verify host ECDSA signature
        guard let hostSigData = Data(hexString: sessionResponse.signatureHex),
              CryptoIdentity.verify(
                signatureRaw: hostSigData,
                for: sessionResponse.signablePayload,
                publicKeyHex: sessionResponse.hostIdentity.publicKeyHex
              ) else {
            throw ClientError.invalidAcknowledgment
        }

        // Derive fresh session keys & deterministic nonce salts bound to master PSK
        let sharedSecret = try clientEphemeral.computeSharedSecret(peerEphemeralPublicKeyHex: sessionResponse.hostEphemeralPublicKeyHex)
        let transcript = sessionInit.signablePayload + sessionResponse.signablePayload
        let keys = SessionKeyDerivation.deriveKeys(
            sharedSecret: sharedSecret,
            sessionId: sessionId,
            transcript: transcript,
            masterPSK: masterPSK
        )

        return EstablishedSession(
            sessionId: sessionId,
            peer: sessionResponse.hostIdentity,
            clientToHostKey: keys.clientToHostKey,
            hostToClientKey: keys.hostToClientKey,
            clientToHostNonceSalt: keys.clientNonceSalt,
            hostToClientNonceSalt: keys.hostNonceSalt
        )
    }

    /// Transmits an authenticated command to the specified Mac endpoint.
    /// Encrypts, signs, transmits, awaits verified acknowledgment, and releases the connection.
    public func sendCommand(
        _ commandType: CommandType,
        to endpoint: NWEndpoint,
        trustedHostPublicKeyHex: String,
        preSharedKeyHex: String? = nil,
        useFreshSession: Bool = true,
        onStateChange: (@Sendable (ConnectionState) -> Void)? = nil
    ) async throws -> CommandAcknowledgment {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "com.handshake.client.dispatch", qos: .userInitiated)

        // Ensure connection is canceled and released upon exit
        defer {
            connection.cancel()
        }

        // 1. Establish connection with timeout
        onStateChange?(.connectingSecurely)
        try await connect(connection: connection, queue: queue, timeoutSeconds: 5.0)

        // 2. Resolve session keys: fresh ephemeral ECDH handshake or fallback
        onStateChange?(.verifyingDevice)
        let sessionKey: SymmetricKey
        let nonceSalt: Data?

        if useFreshSession {
            let masterPSK: SymmetricKey?
            if let hex = preSharedKeyHex, let data = Data(hexString: hex), data.count == 32 {
                masterPSK = SymmetricKey(data: data)
            } else {
                masterPSK = nil
            }
            let session = try await performSessionHandshake(
                connection: connection,
                trustedHostPublicKeyHex: trustedHostPublicKeyHex,
                masterPSK: masterPSK
            )
            sessionKey = session.clientToHostKey
            nonceSalt = session.clientToHostNonceSalt
            onStateChange?(.secureConnectionEstablished(peer: session.peer))
        } else {
            sessionKey = SecureChannel.resolveSessionKey(
                preSharedKeyHex: preSharedKeyHex,
                fallbackPublicKeyHex: clientIdentity.identity.publicKeyHex,
                role: .clientToHost
            )
            nonceSalt = nil
        }

        // 3. Prepare CommandMessage
        let commandMessage = CommandMessage(
            command: commandType,
            timestamp: Date(),
            validityWindowSeconds: 30.0
        )

        // 4. Seal envelope
        let seq = await sequenceCounter.nextOutgoing()
        let envelope = try SecureChannel.seal(
            message: commandMessage,
            sequenceNumber: seq,
            senderIdentity: clientIdentity,
            recipientPublicKeyHex: trustedHostPublicKeyHex,
            sessionKey: sessionKey,
            nonceSalt: nonceSalt
        )

        // 5. Send framed envelope
        onStateChange?(.sendingCommand(commandType))
        let envelopeData = try JSONEncoder().encode(envelope)
        try await NetworkFraming.send(data: envelopeData, over: connection)

        // 6. Receive framed acknowledgment
        let responseData = try await NetworkFraming.receive(from: connection)
        let ack = try JSONDecoder().decode(CommandAcknowledgment.self, from: responseData)

        // 7. Verify Mac's digital signature over acknowledgment
        guard let sigData = Data(hexString: ack.signatureHex),
              CryptoIdentity.verify(
                signatureRaw: sigData,
                for: ack.signablePayload,
                publicKeyHex: ack.hostIdentity.publicKeyHex
              ) else {
            onStateChange?(.commandFailed(reason: "Invalid Mac cryptographic signature"))
            throw ClientError.invalidAcknowledgment
        }

        // 8. Two-Stage Sleep Handshake:
        if commandType == .sleep && (ack.status == .executed || ack.status == .received) {
            let receiptPlaceholder = CommandReceipt(
                commandId: commandMessage.id,
                clientIdentity: clientIdentity.identity
            )
            let sig = try clientIdentity.sign(data: receiptPlaceholder.signablePayload)
            let signedReceipt = CommandReceipt(
                commandId: commandMessage.id,
                timestampMilliseconds: receiptPlaceholder.timestampMilliseconds,
                clientIdentity: clientIdentity.identity,
                signatureHex: sig.hexString
            )
            let receiptData = try JSONEncoder().encode(signedReceipt)
            try await NetworkFraming.send(data: receiptData, over: connection)
        }

        // 9. Check execution status
        switch ack.status {
        case .received, .executed:
            onStateChange?(.commandAccepted(commandType))
            return ack
        case .rejected(let reason):
            onStateChange?(.commandFailed(reason: reason))
            throw ClientError.commandRejected(reason)
        case .failed(let reason):
            onStateChange?(.commandFailed(reason: reason))
            throw ClientError.executionFailed(reason)
        }
    }

    /// Establishes an interactive command session capable of sending multiple commands
    /// sequentially over a single authenticated connection.
    public func openSession(
        to endpoint: NWEndpoint,
        trustedHost: DeviceIdentity,
        preSharedKeyHex: String? = nil,
        useFreshSession: Bool = true,
        timeoutSeconds: TimeInterval = 5.0,
        onStateChange: (@Sendable (ConnectionState) -> Void)? = nil
    ) async throws -> CommandSession {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "com.handshake.client.session.\(UUID().uuidString)", qos: .userInitiated)

        onStateChange?(.connectingSecurely)
        try await connect(connection: connection, queue: queue, timeoutSeconds: timeoutSeconds)

        let establishedSession: EstablishedSession?
        if useFreshSession {
            let masterPSK: SymmetricKey?
            if let hex = preSharedKeyHex, let data = Data(hexString: hex), data.count == 32 {
                masterPSK = SymmetricKey(data: data)
            } else {
                masterPSK = nil
            }
            let session = try await performSessionHandshake(
                connection: connection,
                trustedHostPublicKeyHex: trustedHost.publicKeyHex,
                masterPSK: masterPSK
            )
            establishedSession = session
            onStateChange?(.secureConnectionEstablished(peer: session.peer))
        } else {
            establishedSession = nil
            onStateChange?(.secureConnectionEstablished(peer: trustedHost))
        }

        return CommandSession(
            connection: connection,
            clientIdentity: clientIdentity,
            trustedHost: trustedHost,
            preSharedKeyHex: preSharedKeyHex,
            establishedSession: establishedSession,
            sequenceCounter: sequenceCounter,
            onStateChange: onStateChange
        )
    }

    private func connect(
        connection: NWConnection,
        queue: DispatchQueue,
        timeoutSeconds: TimeInterval
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeState = ResumeLock()

            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                if resumeState.takeResume() {
                    connection.cancel()
                    continuation.resume(throwing: ClientError.timeout)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumeState.takeResume() {
                        continuation.resume()
                    }
                case .failed(let error):
                    if resumeState.takeResume() {
                        connection.cancel()
                        continuation.resume(throwing: ClientError.connectionFailed(error.localizedDescription))
                    }
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }
}

// MARK: - Interactive Command Session

/// Multi-message command session maintaining an open, authenticated connection for sequential commands.
public final class CommandSession: Sendable {
    private let connection: NWConnection
    private let clientIdentity: CryptoIdentity
    private let trustedHost: DeviceIdentity
    private let preSharedKeyHex: String?
    private let establishedSession: EstablishedSession?
    private let sequenceCounter: SequenceCounter
    private let onStateChange: (@Sendable (ConnectionState) -> Void)?

    public init(
        connection: NWConnection,
        clientIdentity: CryptoIdentity,
        trustedHost: DeviceIdentity,
        preSharedKeyHex: String?,
        establishedSession: EstablishedSession? = nil,
        sequenceCounter: SequenceCounter,
        onStateChange: (@Sendable (ConnectionState) -> Void)? = nil
    ) {
        self.connection = connection
        self.clientIdentity = clientIdentity
        self.trustedHost = trustedHost
        self.preSharedKeyHex = preSharedKeyHex
        self.establishedSession = establishedSession
        self.sequenceCounter = sequenceCounter
        self.onStateChange = onStateChange
    }

    public func sendCommand(_ commandType: CommandType) async throws -> CommandAcknowledgment {
        if let session = establishedSession {
            guard !session.isExpired() else {
                onStateChange?(.commandFailed(reason: "Cryptographic session expired"))
                throw HandshakeClient.ClientError.connectionFailed("Session expired")
            }
        }

        let commandMessage = CommandMessage(
            command: commandType,
            timestamp: Date(),
            validityWindowSeconds: 30.0
        )

        let seq = await sequenceCounter.nextOutgoing()
        let sessionKey: SymmetricKey
        let nonceSalt: Data?
        if let session = establishedSession {
            sessionKey = session.clientToHostKey
            nonceSalt = session.clientToHostNonceSalt
        } else {
            sessionKey = SecureChannel.resolveSessionKey(
                preSharedKeyHex: preSharedKeyHex,
                fallbackPublicKeyHex: clientIdentity.identity.publicKeyHex,
                role: .clientToHost
            )
            nonceSalt = nil
        }

        let envelope = try SecureChannel.seal(
            message: commandMessage,
            sequenceNumber: seq,
            senderIdentity: clientIdentity,
            recipientPublicKeyHex: trustedHost.publicKeyHex,
            sessionKey: sessionKey,
            nonceSalt: nonceSalt
        )

        onStateChange?(.sendingCommand(commandType))
        let envelopeData = try JSONEncoder().encode(envelope)
        try await NetworkFraming.send(data: envelopeData, over: connection)

        let responseData = try await NetworkFraming.receive(from: connection)
        let ack = try JSONDecoder().decode(CommandAcknowledgment.self, from: responseData)

        guard let sigData = Data(hexString: ack.signatureHex),
              CryptoIdentity.verify(
                signatureRaw: sigData,
                for: ack.signablePayload,
                publicKeyHex: ack.hostIdentity.publicKeyHex
              ) else {
            onStateChange?(.commandFailed(reason: "Invalid Mac cryptographic signature"))
            throw HandshakeClient.ClientError.invalidAcknowledgment
        }

        if commandType == .sleep && (ack.status == .executed || ack.status == .received) {
            let receiptPlaceholder = CommandReceipt(commandId: commandMessage.id, clientIdentity: clientIdentity.identity)
            let sig = try clientIdentity.sign(data: receiptPlaceholder.signablePayload)
            let signedReceipt = CommandReceipt(
                commandId: commandMessage.id,
                timestampMilliseconds: receiptPlaceholder.timestampMilliseconds,
                clientIdentity: clientIdentity.identity,
                signatureHex: sig.hexString
            )
            let receiptData = try JSONEncoder().encode(signedReceipt)
            try await NetworkFraming.send(data: receiptData, over: connection)
        }

        switch ack.status {
        case .received, .executed:
            onStateChange?(.commandAccepted(commandType))
            return ack
        case .rejected(let reason):
            onStateChange?(.commandFailed(reason: reason))
            throw HandshakeClient.ClientError.commandRejected(reason)
        case .failed(let reason):
            onStateChange?(.commandFailed(reason: reason))
            throw HandshakeClient.ClientError.executionFailed(reason)
        }
    }

    public func close() {
        connection.cancel()
    }

    deinit {
        connection.cancel()
    }
}

// MARK: - Thread-safe Atomic Continuation Helper

private final class ResumeLock: @unchecked Sendable {
    private let lock = NSLock()
    private var isResumed = false

    func takeResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !isResumed {
            isResumed = true
            return true
        }
        return false
    }
}
