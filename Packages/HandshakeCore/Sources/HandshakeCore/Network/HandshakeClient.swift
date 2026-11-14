import Foundation
import Network
import CryptoKit

/// Local peer-to-peer TCP client for the iPhone application.
/// Connects to a paired Mac companion on demand, issues signed command envelopes,
/// awaits verified cryptographic acknowledgments, and terminates immediately.
public final class HandshakeClient: Sendable {

    public enum ClientError: Error, LocalizedError {
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
    public func discoverMac(
        serviceType: String = "_handshake._tcp",
        timeoutSeconds: TimeInterval = 3.0
    ) async throws -> NWEndpoint {
        let browserParams = NWParameters()
        browserParams.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: browserParams)

        return try await withCheckedThrowingContinuation { continuation in
            let resumeState = ResumeLock()
            let queue = DispatchQueue(label: "com.handshake.client.discovery", qos: .userInitiated)

            // Setup timeout timer
            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                if resumeState.takeResume() {
                    browser.cancel()
                    continuation.resume(throwing: ClientError.macNotFound)
                }
            }

            browser.browseResultsChangedHandler = { results, _ in
                guard let first = results.first else { return }
                if resumeState.takeResume() {
                    browser.cancel()
                    continuation.resume(returning: first.endpoint)
                }
            }

            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    if resumeState.takeResume() {
                        browser.cancel()
                        continuation.resume(throwing: ClientError.connectionFailed(error.localizedDescription))
                    }
                }
            }

            browser.start(queue: queue)
        }
    }

    // MARK: - Command Dispatch

    /// Transmits an authenticated command to the specified Mac endpoint.
    /// Encrypts, signs, transmits, awaits verified acknowledgment, and releases the connection.
    public func sendCommand(
        _ commandType: CommandType,
        to endpoint: NWEndpoint,
        trustedHostPublicKeyHex: String
    ) async throws -> CommandAcknowledgment {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "com.handshake.client.dispatch", qos: .userInitiated)

        // Ensure connection is canceled and released upon exit
        defer {
            connection.cancel()
        }

        // 1. Establish connection with timeout
        try await connect(connection: connection, queue: queue, timeoutSeconds: 5.0)

        // 2. Prepare CommandMessage
        let commandMessage = CommandMessage(
            command: commandType,
            timestamp: Date(),
            validityWindowSeconds: 30.0
        )

        // 3. Seal envelope
        let seq = await sequenceCounter.nextOutgoing()
        let senderKeyData = Data(hexString: clientIdentity.identity.publicKeyHex) ?? Data()
        let sessionKey = SymmetricKey(data: SHA256.hash(data: senderKeyData))

        let envelope = try SecureChannel.seal(
            message: commandMessage,
            sequenceNumber: seq,
            senderIdentity: clientIdentity,
            recipientPublicKeyHex: trustedHostPublicKeyHex,
            sessionKey: sessionKey
        )

        // 4. Send framed envelope
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
            throw ClientError.invalidAcknowledgment
        }

        // 7. Two-Stage Sleep Handshake:
        // When the sleep command is accepted, transmit a signed CommandReceipt confirmation
        // to inform the Mac that its acknowledgment was verified before power-down begins
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
            return ack
        case .rejected(let reason):
            throw ClientError.commandRejected(reason)
        case .failed(let reason):
            throw ClientError.executionFailed(reason)
        }
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
