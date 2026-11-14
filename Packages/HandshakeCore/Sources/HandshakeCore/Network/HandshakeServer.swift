import Foundation
import Network
import CryptoKit

/// Local peer-to-peer TCP server for the host Mac companion.
/// Advertises `_handshake._tcp` via Bonjour and receives authenticated commands
/// strictly while the application's main window remains open.
public actor HandshakeServer {

    public typealias CommandExecutionHandler = @Sendable (CommandMessage, DeviceIdentity) async -> CommandAcknowledgment.ExecutionStatus

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
    private let sequenceCounter: SequenceCounter
    private let executionHandler: CommandExecutionHandler

    private var listener: NWListener?
    private var running: Bool = false

    public init(
        port: UInt16 = 5894,
        serviceType: String = "_handshake._tcp",
        hostIdentity: CryptoIdentity,
        trustStore: TrustStore,
        sequenceCounter: SequenceCounter = SequenceCounter(),
        executionHandler: @escaping CommandExecutionHandler
    ) {
        self.port = port
        self.serviceType = serviceType
        self.hostIdentity = hostIdentity
        self.trustStore = trustStore
        self.sequenceCounter = sequenceCounter
        self.executionHandler = executionHandler
    }

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

            // Bonjour service advertisement
            newListener.service = NWListener.Service(
                name: hostIdentity.identity.displayName,
                type: serviceType
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

    /// Stops the local listener and releases all networking resources.
    public func stop() {
        guard running else { return }
        listener?.cancel()
        listener = nil
        running = false
    }

    public var isRunning: Bool {
        return running
    }

    // MARK: - Inbound Connection Processing

    private func handleIncomingConnection(_ connection: NWConnection) {
        let queue = DispatchQueue(label: "com.handshake.server.connection.\(UUID().uuidString)", qos: .userInitiated)
        connection.start(queue: queue)

        Task {
            defer {
                connection.cancel()
            }

            do {
                // 1. Read framed envelope packet
                let rawData = try await NetworkFraming.receive(from: connection)
                let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: rawData)

                // 2. Validate sender against Trust Store
                guard let trustRecord = await trustStore.getRecord(publicKeyHex: envelope.senderPublicKeyHex) else {
                    try await sendRejection(
                        commandId: envelope.id,
                        reason: "Device is not paired or recognized.",
                        over: connection
                    )
                    return
                }

                guard !trustRecord.isRevoked else {
                    try await sendRejection(
                        commandId: envelope.id,
                        reason: "Device trust has been revoked.",
                        over: connection
                    )
                    return
                }

                // 3. Authenticate and decrypt envelope
                let senderKeyData = Data(hexString: envelope.senderPublicKeyHex) ?? Data()
                let sessionKey = SymmetricKey(data: SHA256.hash(data: senderKeyData))

                let message: CommandMessage
                do {
                    message = try await SecureChannel.open(
                        envelope: envelope,
                        sessionKey: sessionKey,
                        trustedSenderPublicKeyHex: trustRecord.peer.publicKeyHex,
                        sequenceCounter: sequenceCounter
                    )
                } catch {
                    try await sendRejection(
                        commandId: envelope.id,
                        reason: "Authentication failed: \(error.localizedDescription)",
                        over: connection
                    )
                    return
                }

                // 4. Verify command type is authorized in trust record
                guard trustRecord.authorizedCapabilities.contains(message.command) else {
                    try await sendRejection(
                        commandId: envelope.id,
                        reason: "Command \(message.command.displayName) not authorized for this device.",
                        over: connection
                    )
                    return
                }

                // 5. Update last seen timestamp
                try? await trustStore.updateLastSeen(id: trustRecord.id)

                // 6. Execute authorized command on host Mac
                let status = await executionHandler(message, trustRecord.peer)

                // 7. Send signed acknowledgment
                let ack = try makeAcknowledgment(commandId: message.id, status: status)
                let ackData = try JSONEncoder().encode(ack)
                try await NetworkFraming.send(data: ackData, over: connection)

                // 8. Orderly sleep post-processing: flush TCP buffers and initiate sleep if commanded
                if message.command == .sleep, case .executed = status {
                    #if os(macOS)
                    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms TCP buffer flush
                    _ = MacSleepEngine().triggerSleep()
                    #endif
                }

            } catch {
                // Connection error or malformed frame: fail closed
            }
        }
    }

    private func sendRejection(
        commandId: UUID,
        reason: String,
        over connection: NWConnection
    ) async throws {
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
