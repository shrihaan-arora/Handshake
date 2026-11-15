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
        timeoutSeconds: TimeInterval = 3.5,
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
                        // Fall back to name match if TXT record is omitted or in transit
                        if !isMatch && matchedName == target.displayName {
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

    // MARK: - Command Dispatch

    /// Transmits an authenticated command to the specified Mac endpoint.
    /// Encrypts, signs, transmits, awaits verified acknowledgment, and releases the connection.
    public func sendCommand(
        _ commandType: CommandType,
        to endpoint: NWEndpoint,
        trustedHostPublicKeyHex: String,
        preSharedKeyHex: String? = nil,
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

        // 2. Prepare CommandMessage
        let commandMessage = CommandMessage(
            command: commandType,
            timestamp: Date(),
            validityWindowSeconds: 30.0
        )

        // 3. Resolve directional session key and seal envelope
        onStateChange?(.verifyingDevice)
        let seq = await sequenceCounter.nextOutgoing()
        let sessionKey = SecureChannel.resolveSessionKey(
            preSharedKeyHex: preSharedKeyHex,
            fallbackPublicKeyHex: clientIdentity.identity.publicKeyHex,
            role: .clientToHost
        )

        let envelope = try SecureChannel.seal(
            message: commandMessage,
            sequenceNumber: seq,
            senderIdentity: clientIdentity,
            recipientPublicKeyHex: trustedHostPublicKeyHex,
            sessionKey: sessionKey
        )

        // 4. Send framed envelope
        onStateChange?(.sendingCommand(commandType))
        let envelopeData = try JSONEncoder().encode(envelope)
        try await NetworkFraming.send(data: envelopeData, over: connection)

        // 5. Receive framed acknowledgment
        let responseData = try await NetworkFraming.receive(from: connection)
        let ack = try JSONDecoder().decode(CommandAcknowledgment.self, from: responseData)

        // 6. Verify Mac's digital signature over acknowledgment
        guard let sigData = Data(hexString: ack.signatureHex),
              CryptoIdentity.verify(
                signatureRaw: sigData,
                for: ack.signablePayload,
                publicKeyHex: ack.hostIdentity.publicKeyHex
              ) else {
            onStateChange?(.commandFailed(reason: "Invalid Mac cryptographic signature"))
            throw ClientError.invalidAcknowledgment
        }

        // 7. Two-Stage Sleep Handshake:
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

        // 8. Check execution status
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
        timeoutSeconds: TimeInterval = 5.0,
        onStateChange: (@Sendable (ConnectionState) -> Void)? = nil
    ) async throws -> CommandSession {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "com.handshake.client.session.\(UUID().uuidString)", qos: .userInitiated)

        onStateChange?(.connectingSecurely)
        try await connect(connection: connection, queue: queue, timeoutSeconds: timeoutSeconds)
        onStateChange?(.secureConnectionEstablished(peer: trustedHost))

        return CommandSession(
            connection: connection,
            clientIdentity: clientIdentity,
            trustedHost: trustedHost,
            preSharedKeyHex: preSharedKeyHex,
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
    private let sequenceCounter: SequenceCounter
    private let onStateChange: (@Sendable (ConnectionState) -> Void)?

    public init(
        connection: NWConnection,
        clientIdentity: CryptoIdentity,
        trustedHost: DeviceIdentity,
        preSharedKeyHex: String?,
        sequenceCounter: SequenceCounter,
        onStateChange: (@Sendable (ConnectionState) -> Void)? = nil
    ) {
        self.connection = connection
        self.clientIdentity = clientIdentity
        self.trustedHost = trustedHost
        self.preSharedKeyHex = preSharedKeyHex
        self.sequenceCounter = sequenceCounter
        self.onStateChange = onStateChange
    }

    public func sendCommand(_ commandType: CommandType) async throws -> CommandAcknowledgment {
        let commandMessage = CommandMessage(
            command: commandType,
            timestamp: Date(),
            validityWindowSeconds: 30.0
        )

        let seq = await sequenceCounter.nextOutgoing()
        let sessionKey = SecureChannel.resolveSessionKey(
            preSharedKeyHex: preSharedKeyHex,
            fallbackPublicKeyHex: clientIdentity.identity.publicKeyHex,
            role: .clientToHost
        )

        let envelope = try SecureChannel.seal(
            message: commandMessage,
            sequenceNumber: seq,
            senderIdentity: clientIdentity,
            recipientPublicKeyHex: trustedHost.publicKeyHex,
            sessionKey: sessionKey
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
