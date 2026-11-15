import XCTest
import CryptoKit
import Network
@testable import HandshakeCore

final class CommandPipelineTests: XCTestCase {

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private let testKeychain = KeychainManager(service: "com.handshake.test.commandpipeline")

    override func tearDown() {
        super.tearDown()
        try? testKeychain.delete(account: "cmd.pipe.host.truststore")
        try? testKeychain.delete(account: "cmd.pipe.client.truststore")
        try? testKeychain.delete(account: "cmd.pipe.host.id.privateKey")
        try? testKeychain.delete(account: "cmd.pipe.host.id.metadata")
        try? testKeychain.delete(account: "cmd.pipe.client.id.privateKey")
        try? testKeychain.delete(account: "cmd.pipe.client.id.metadata")
    }

    private func createTestIdentities() throws -> (host: CryptoIdentity, client: CryptoIdentity) {
        let host = try CryptoIdentity.createNew(
            label: "cmd.pipe.host.id",
            displayName: "MacBook Air M4",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 15.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let client = try CryptoIdentity.createNew(
            label: "cmd.pipe.client.id",
            displayName: "iPhone 16e",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "iOS 18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        return (host, client)
    }

    // MARK: - 1. Happy Path Lock Screen Execution Pipeline

    func testCommandPipelineLockScreenHappyPath() async throws {
        let (host, client) = try createTestIdentities()
        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "cmd.pipe.host.truststore")
        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }

        try await hostTrustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.lockScreen, .sleep],
            preSharedKeyHex: pskHex
        ))

        let port: UInt16 = 5881
        let commandExecuted = Box(false)

        let server = HandshakeServer(
            port: port,
            serviceType: "_handshake._tcp",
            hostIdentity: host,
            trustStore: hostTrustStore,
            executionHandler: { message, peer in
                XCTAssertEqual(message.command, .lockScreen)
                XCTAssertEqual(peer.publicKeyHex, client.identity.publicKeyHex)
                commandExecuted.value = true
                return .executed
            }
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let clientSequence = SequenceCounter()
        let clientInstance = HandshakeClient(clientIdentity: client, sequenceCounter: clientSequence)

        let progressionStates = Box<[ConnectionState]>([])
        let ack = try await clientInstance.sendCommand(
            .lockScreen,
            to: .hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port)),
            trustedHostPublicKeyHex: host.identity.publicKeyHex,
            preSharedKeyHex: pskHex,
            useFreshSession: true,
            onStateChange: { state in
                progressionStates.value.append(state)
            }
        )

        XCTAssertTrue(commandExecuted.value)
        XCTAssertEqual(ack.status, .executed)
        XCTAssertEqual(ack.hostIdentity.publicKeyHex, host.identity.publicKeyHex)
        XCTAssertFalse(ack.signatureHex.isEmpty)

        // Verify progression states contain sending, executing, and completed
        let hasSending = progressionStates.value.contains(where: {
            if case .sendingCommand(let cmd) = $0, cmd == .lockScreen { return true }
            return false
        })
        let hasExecuting = progressionStates.value.contains(where: {
            if case .executingCommand(let cmd) = $0, cmd == .lockScreen { return true }
            return false
        })
        let hasCompleted = progressionStates.value.contains(where: {
            if case .commandCompleted(let cmd) = $0, cmd == .lockScreen { return true }
            return false
        })

        XCTAssertTrue(hasSending, "Missing .sendingCommand state progression")
        XCTAssertTrue(hasExecuting, "Missing .executingCommand state progression")
        XCTAssertTrue(hasCompleted, "Missing .commandCompleted state progression")
    }

    // MARK: - 2. Happy Path Sleep Execution Pipeline with Two-Stage Handshake

    func testCommandPipelineSleepHappyPathWithTwoStageReceipt() async throws {
        let (host, client) = try createTestIdentities()
        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "cmd.pipe.host.truststore")
        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }

        try await hostTrustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.sleep],
            preSharedKeyHex: pskHex
        ))

        let port: UInt16 = 5882
        let sleepPrepared = Box(false)

        #if os(macOS)
        let sleepTriggered = Box(false)
        let sleepEngine = MacSleepEngine(customSleepTrigger: {
            sleepTriggered.value = true
            return .sleepInitiated
        })
        #endif

        let server: HandshakeServer
        #if os(macOS)
        server = HandshakeServer(
            port: port,
            serviceType: "_handshake._tcp",
            hostIdentity: host,
            trustStore: hostTrustStore,
            sleepEngine: sleepEngine,
            executionHandler: { message, peer in
                XCTAssertEqual(message.command, .sleep)
                sleepPrepared.value = true
                return .executed
            }
        )
        #else
        server = HandshakeServer(
            port: port,
            serviceType: "_handshake._tcp",
            hostIdentity: host,
            trustStore: hostTrustStore,
            executionHandler: { message, peer in
                XCTAssertEqual(message.command, .sleep)
                sleepPrepared.value = true
                return .executed
            }
        )
        #endif
        try await server.start()
        defer { Task { await server.stop() } }

        let clientSequence = SequenceCounter()
        let clientInstance = HandshakeClient(clientIdentity: client, sequenceCounter: clientSequence)

        let ack = try await clientInstance.sendCommand(
            .sleep,
            to: .hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port)),
            trustedHostPublicKeyHex: host.identity.publicKeyHex,
            preSharedKeyHex: pskHex,
            useFreshSession: true
        )

        XCTAssertTrue(sleepPrepared.value)
        XCTAssertEqual(ack.status, .executed)

        #if os(macOS)
        // Wait for server to process receipt and trigger sleep
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(sleepTriggered.value)
        #endif
    }

    // MARK: - 3. Reject Unauthorized Capability

    func testCommandPipelineRejectUnauthorizedCapability() async throws {
        let (host, client) = try createTestIdentities()
        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "cmd.pipe.host.truststore")
        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }

        // Peer is only authorized for .ping, NOT .lockScreen
        try await hostTrustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.ping],
            preSharedKeyHex: pskHex
        ))

        let port: UInt16 = 5883
        let server = HandshakeServer(
            port: port,
            serviceType: "_handshake._tcp",
            hostIdentity: host,
            trustStore: hostTrustStore,
            executionHandler: { _, _ in
                XCTFail("Execution handler should never be invoked for unauthorized capability")
                return .executed
            }
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let clientSequence = SequenceCounter()
        let clientInstance = HandshakeClient(clientIdentity: client, sequenceCounter: clientSequence)

        do {
            _ = try await clientInstance.sendCommand(
                .lockScreen,
                to: .hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port)),
                trustedHostPublicKeyHex: host.identity.publicKeyHex,
                preSharedKeyHex: pskHex,
                useFreshSession: true
            )
            XCTFail("Expected sendCommand to throw ClientError.commandRejected")
        } catch let err as HandshakeClient.ClientError {
            guard case .commandRejected(let reason) = err else {
                return XCTFail("Expected .commandRejected, got: \(err)")
            }
            XCTAssertTrue(reason.contains("not authorized"))
        }
    }

    // MARK: - 4. Duplicate Command Request ID Rejection

    func testCommandPipelineDuplicateCommandIdRejection() async throws {
        let (host, client) = try createTestIdentities()
        let hostTrustStore = TrustStore(keychain: testKeychain, storageAccount: "cmd.pipe.host.truststore")
        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }

        try await hostTrustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.lockScreen],
            preSharedKeyHex: pskHex
        ))

        let port: UInt16 = 5884
        let executionCount = Box(0)

        let server = HandshakeServer(
            port: port,
            serviceType: "_handshake._tcp",
            hostIdentity: host,
            trustStore: hostTrustStore,
            executionHandler: { _, _ in
                executionCount.value += 1
                return .executed
            }
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let sessionKey = SecureChannel.resolveSessionKey(
            preSharedKeyHex: pskHex,
            fallbackPublicKeyHex: client.identity.publicKeyHex,
            role: .clientToHost
        )

        let duplicateId = UUID()
        let cmd = CommandMessage(id: duplicateId, command: .lockScreen)

        // Transmission 1: Valid sequence 1, unique ID
        let env1 = try SecureChannel.seal(
            message: cmd,
            sequenceNumber: 1,
            senderIdentity: client,
            recipientPublicKeyHex: host.identity.publicKeyHex,
            sessionKey: sessionKey
        )
        let framed1 = try NetworkFraming.frame(data: JSONEncoder().encode(env1))
        let resp1 = try await sendRawPacket(framed1, to: port)
        let ack1 = try JSONDecoder().decode(CommandAcknowledgment.self, from: resp1)
        XCTAssertEqual(ack1.status, .executed)
        XCTAssertEqual(executionCount.value, 1)

        // Transmission 2: Valid sequence 2 (so not a sequence replay), but DUPLICATE message ID
        let env2 = try SecureChannel.seal(
            message: cmd,
            sequenceNumber: 2,
            senderIdentity: client,
            recipientPublicKeyHex: host.identity.publicKeyHex,
            sessionKey: sessionKey
        )
        let framed2 = try NetworkFraming.frame(data: JSONEncoder().encode(env2))
        let resp2 = try await sendRawPacket(framed2, to: port)
        let ack2 = try JSONDecoder().decode(CommandAcknowledgment.self, from: resp2)

        XCTAssertEqual(ack2.commandId, duplicateId)
        XCTAssertEqual(ack2.status, .rejected("Duplicate command request ID rejected."))
        // Execution count must remain 1 — prevented duplicate execution!
        XCTAssertEqual(executionCount.value, 1)
    }

    // MARK: - Helper

    private func sendRawPacket(_ data: Data, to port: UInt16) async throws -> Data {
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "test.cmd.pipe.raw")
        connection.start(queue: queue)

        defer { connection.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume()
                case .failed(let err): continuation.resume(throwing: err)
                default: break
                }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err = err { continuation.resume(throwing: err) }
                else { continuation.resume() }
            })
        }

        return try await NetworkFraming.receive(from: connection)
    }
}
