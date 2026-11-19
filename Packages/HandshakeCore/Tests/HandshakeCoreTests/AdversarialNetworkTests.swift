import XCTest
import Network
import CryptoKit
@testable import HandshakeCore

final class AdversarialNetworkTests: XCTestCase {

    private let testKeychain = KeychainManager(service: "com.handshake.test.adversarial")
    private var serverPortCounter: UInt16 = 5910
    private var activeServers: [HandshakeServer] = []

    private func getNextPort() -> UInt16 {
        serverPortCounter += 1
        return serverPortCounter
    }

    override func tearDown() async throws {
        for server in activeServers {
            await server.stop()
        }
        activeServers.removeAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    // MARK: - Helpers

    private func makeHost(label: String) throws -> CryptoIdentity {
        return try CryptoIdentity.createNew(
            label: label,
            displayName: "Test Host Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "15.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
    }

    private func makeClient(label: String, name: String = "Test iPhone") throws -> CryptoIdentity {
        return try CryptoIdentity.createNew(
            label: label,
            displayName: name,
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
    }

    #if os(macOS)
    private func makeSafeServer(
        port: UInt16,
        host: CryptoIdentity,
        trustStore: TrustStore,
        sequenceCounter: SequenceCounter = SequenceCounter(),
        executionHandler: @escaping HandshakeServer.CommandExecutionHandler = { _, _ in .executed }
    ) -> HandshakeServer {
        // Safe test double: customSleepTrigger avoids ever putting the host machine to sleep
        let safeSleepEngine = MacSleepEngine(customSleepTrigger: { .sleepInitiated })
        let server = HandshakeServer(
            port: port,
            serviceType: "_advtest._tcp",
            hostIdentity: host,
            trustStore: trustStore,
            sequenceCounter: sequenceCounter,
            sleepEngine: safeSleepEngine,
            executionHandler: executionHandler
        )
        activeServers.append(server)
        return server
    }
    #else
    private func makeSafeServer(
        port: UInt16,
        host: CryptoIdentity,
        trustStore: TrustStore,
        sequenceCounter: SequenceCounter = SequenceCounter(),
        executionHandler: @escaping HandshakeServer.CommandExecutionHandler = { _, _ in .executed }
    ) -> HandshakeServer {
        let server = HandshakeServer(
            port: port,
            serviceType: "_advtest._tcp",
            hostIdentity: host,
            trustStore: trustStore,
            sequenceCounter: sequenceCounter,
            executionHandler: executionHandler
        )
        activeServers.append(server)
        return server
    }
    #endif

    private func sendRawData(_ data: Data, to port: UInt16, timeoutSeconds: TimeInterval = 3.0) async throws -> Data {
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "com.handshake.rawclient", qos: .userInitiated)

        defer {
            connection.cancel()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let err):
                    continuation.resume(throwing: err)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err = err {
                    continuation.resume(throwing: err)
                } else {
                    continuation.resume()
                }
            })
        }

        return try await NetworkFraming.receive(from: connection)
    }

    // MARK: - Test 1: Unknown Device Connection Fails Closed

    func test01_UnknownDeviceConnectionFailsClosed() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "adv.host.01")
        let legitimateClient = try makeClient(label: "adv.legit.01")
        let rogueClient = try makeClient(label: "adv.rogue.01", name: "Rogue Phone")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "adv.ts.01")
        try await trustStore.addOrUpdate(TrustRecord(peer: legitimateClient.identity, authorizedCapabilities: [.lockScreen]))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let rogue = HandshakeClient(clientIdentity: rogueClient)
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))

        do {
            _ = try await rogue.sendCommand(.lockScreen, to: endpoint, trustedHostPublicKeyHex: host.identity.publicKeyHex)
            XCTFail("Unknown device connection must be rejected")
        } catch let err as HandshakeClient.ClientError {
            guard case .commandRejected(let reason) = err else {
                XCTFail("Expected commandRejected error, got: \(err)")
                return
            }
            XCTAssertTrue(reason.contains("not paired or recognized"), "Reason was: \(reason)")
        }
    }

    // MARK: - Test 2: Replayed Packet Rejected by Sequence Counter

    func test02_ReplayedPacketRejectedBySequenceCounter() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "adv.host.02")
        let client = try makeClient(label: "adv.client.02")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "adv.ts.02")
        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }
        try await trustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.lockScreen],
            preSharedKeyHex: pskHex
        ))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        // Create a sealed envelope with fixed sequence number = 10
        let sessionKey = try SecureChannel.resolveSessionKey(preSharedKeyHex: pskHex, role: .clientToHost)
        let cmd = CommandMessage(command: .lockScreen)
        let envelope = try SecureChannel.seal(
            message: cmd,
            sequenceNumber: 10,
            senderIdentity: client,
            recipientPublicKeyHex: host.identity.publicKeyHex,
            sessionKey: sessionKey
        )
        let framedEnvelope = try NetworkFraming.frame(data: JSONEncoder().encode(envelope))

        // First transmission: must succeed
        let resp1 = try await sendRawData(framedEnvelope, to: port)
        let ack1 = try JSONDecoder().decode(CommandAcknowledgment.self, from: resp1)
        XCTAssertEqual(ack1.status, .executed)

        // Second transmission of identical packet: MUST fail closed
        let resp2 = try await sendRawData(framedEnvelope, to: port)
        let ack2 = try JSONDecoder().decode(CommandAcknowledgment.self, from: resp2)
        guard case .rejected(let reason) = ack2.status else {
            XCTFail("Replayed packet must be rejected, got: \(ack2.status)")
            return
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("replay") || reason.localizedCaseInsensitiveContains("sequence"), "Reason was: \(reason)")
    }

    // MARK: - Test 3: Tampered Ciphertext Fails Decryption

    func test03_TamperedCiphertextFailsDecryption() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "adv.host.03")
        let client = try makeClient(label: "adv.client.03")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "adv.ts.03")
        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }
        try await trustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.lockScreen],
            preSharedKeyHex: pskHex
        ))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let sessionKey = try SecureChannel.resolveSessionKey(preSharedKeyHex: pskHex, role: .clientToHost)
        let cmd = CommandMessage(command: .lockScreen)
        let validEnvelope = try SecureChannel.seal(
            message: cmd,
            sequenceNumber: 1,
            senderIdentity: client,
            recipientPublicKeyHex: host.identity.publicKeyHex,
            sessionKey: sessionKey
        )

        // Flip bits in ciphertext
        guard var cipherData = Data(hexString: validEnvelope.ciphertextHex), !cipherData.isEmpty else {
            XCTFail("Missing ciphertext")
            return
        }
        cipherData[0] ^= 0xFF
        let tamperedEnvelope = CommandEnvelope(
            version: validEnvelope.version,
            id: validEnvelope.id,
            senderPublicKeyHex: validEnvelope.senderPublicKeyHex,
            recipientPublicKeyHex: validEnvelope.recipientPublicKeyHex,
            sequenceNumber: validEnvelope.sequenceNumber,
            timestampMilliseconds: validEnvelope.timestampMilliseconds,
            nonceHex: validEnvelope.nonceHex,
            ciphertextHex: cipherData.hexString,
            authTagHex: validEnvelope.authTagHex,
            signatureHex: validEnvelope.signatureHex
        )

        let framed = try NetworkFraming.frame(data: JSONEncoder().encode(tamperedEnvelope))
        let resp = try await sendRawData(framed, to: port)
        let ack = try JSONDecoder().decode(CommandAcknowledgment.self, from: resp)

        guard case .rejected(let reason) = ack.status else {
            XCTFail("Tampered ciphertext must be rejected, got: \(ack.status)")
            return
        }
        XCTAssertTrue(reason.contains("Authentication failed"), "Expected auth failure, got: \(reason)")
    }

    // MARK: - Test 4: Modified Auth Tag Fails AEAD Open

    func test04_ModifiedAuthTagFailsAEADOpen() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "adv.host.04")
        let client = try makeClient(label: "adv.client.04")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "adv.ts.04")
        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }
        try await trustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.lockScreen],
            preSharedKeyHex: pskHex
        ))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let sessionKey = try SecureChannel.resolveSessionKey(preSharedKeyHex: pskHex, role: .clientToHost)
        let cmd = CommandMessage(command: .lockScreen)
        let validEnvelope = try SecureChannel.seal(
            message: cmd,
            sequenceNumber: 1,
            senderIdentity: client,
            recipientPublicKeyHex: host.identity.publicKeyHex,
            sessionKey: sessionKey
        )

        // Modify auth tag (16 bytes)
        let tamperedAuthTag = "00112233445566778899aabbccddeeff"
        let tamperedEnvelope = CommandEnvelope(
            version: validEnvelope.version,
            id: validEnvelope.id,
            senderPublicKeyHex: validEnvelope.senderPublicKeyHex,
            recipientPublicKeyHex: validEnvelope.recipientPublicKeyHex,
            sequenceNumber: validEnvelope.sequenceNumber,
            timestampMilliseconds: validEnvelope.timestampMilliseconds,
            nonceHex: validEnvelope.nonceHex,
            ciphertextHex: validEnvelope.ciphertextHex,
            authTagHex: tamperedAuthTag,
            signatureHex: validEnvelope.signatureHex
        )

        let framed = try NetworkFraming.frame(data: JSONEncoder().encode(tamperedEnvelope))
        let resp = try await sendRawData(framed, to: port)
        let ack = try JSONDecoder().decode(CommandAcknowledgment.self, from: resp)

        guard case .rejected(let reason) = ack.status else {
            XCTFail("Modified auth tag must be rejected, got: \(ack.status)")
            return
        }
        XCTAssertTrue(reason.contains("Authentication failed"), "Expected auth failure, got: \(reason)")
    }

    // MARK: - Test 5: Forged Command Fails ECDSA Verification

    func test05_ForgedCommandFailsECDSAVerification() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "adv.host.05")
        let client = try makeClient(label: "adv.client.05")
        let forger = try makeClient(label: "adv.forger.05")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "adv.ts.05")
        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }
        try await trustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.lockScreen],
            preSharedKeyHex: pskHex
        ))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let sessionKey = try SecureChannel.resolveSessionKey(preSharedKeyHex: pskHex, role: .clientToHost)
        let cmd = CommandMessage(command: .lockScreen)
        // Forger signs envelope while claiming to be client
        let forgedEnvelope = try SecureChannel.seal(
            message: cmd,
            sequenceNumber: 1,
            senderIdentity: forger,
            recipientPublicKeyHex: host.identity.publicKeyHex,
            sessionKey: sessionKey
        )

        // Spoof sender public key header to match client
        let spoofedEnvelope = CommandEnvelope(
            version: forgedEnvelope.version,
            id: forgedEnvelope.id,
            senderPublicKeyHex: client.identity.publicKeyHex, // Spoofed!
            recipientPublicKeyHex: forgedEnvelope.recipientPublicKeyHex,
            sequenceNumber: forgedEnvelope.sequenceNumber,
            timestampMilliseconds: forgedEnvelope.timestampMilliseconds,
            nonceHex: forgedEnvelope.nonceHex,
            ciphertextHex: forgedEnvelope.ciphertextHex,
            authTagHex: forgedEnvelope.authTagHex,
            signatureHex: forgedEnvelope.signatureHex
        )

        let framed = try NetworkFraming.frame(data: JSONEncoder().encode(spoofedEnvelope))
        let resp = try await sendRawData(framed, to: port)
        let ack = try JSONDecoder().decode(CommandAcknowledgment.self, from: resp)

        guard case .rejected(let reason) = ack.status else {
            XCTFail("Forged signature must be rejected, got: \(ack.status)")
            return
        }
        XCTAssertTrue(reason.contains("Authentication failed") || reason.contains("signature"), "Reason was: \(reason)")
    }

    // MARK: - Test 6: Invalid Signature Syntax Or Random Bytes

    func test06_InvalidSignatureSyntaxOrBytes() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "adv.host.06")
        let client = try makeClient(label: "adv.client.06")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "adv.ts.06")
        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }
        try await trustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.lockScreen],
            preSharedKeyHex: pskHex
        ))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let sessionKey = try SecureChannel.resolveSessionKey(preSharedKeyHex: pskHex, role: .clientToHost)
        let cmd = CommandMessage(command: .lockScreen)
        let validEnvelope = try SecureChannel.seal(
            message: cmd,
            sequenceNumber: 1,
            senderIdentity: client,
            recipientPublicKeyHex: host.identity.publicKeyHex,
            sessionKey: sessionKey
        )

        let badSigEnvelope = CommandEnvelope(
            version: validEnvelope.version,
            id: validEnvelope.id,
            senderPublicKeyHex: validEnvelope.senderPublicKeyHex,
            recipientPublicKeyHex: validEnvelope.recipientPublicKeyHex,
            sequenceNumber: validEnvelope.sequenceNumber,
            timestampMilliseconds: validEnvelope.timestampMilliseconds,
            nonceHex: validEnvelope.nonceHex,
            ciphertextHex: validEnvelope.ciphertextHex,
            authTagHex: validEnvelope.authTagHex,
            signatureHex: "deadbeefcafebabe" // Corrupt 8-byte hex string
        )

        let framed = try NetworkFraming.frame(data: JSONEncoder().encode(badSigEnvelope))
        let resp = try await sendRawData(framed, to: port)
        let ack = try JSONDecoder().decode(CommandAcknowledgment.self, from: resp)

        guard case .rejected(let reason) = ack.status else {
            XCTFail("Corrupt signature must be rejected, got: \(ack.status)")
            return
        }
        XCTAssertTrue(reason.contains("Authentication failed"), "Reason: \(reason)")
    }

    // MARK: - Test 7: Expired Session / Clock Skew Exceeded

    func test07_ClockSkewExceededRejected() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "adv.host.07")
        let client = try makeClient(label: "adv.client.07")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "adv.ts.07")
        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }
        try await trustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.lockScreen],
            preSharedKeyHex: pskHex
        ))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let sessionKey = try SecureChannel.resolveSessionKey(preSharedKeyHex: pskHex, role: .clientToHost)

        // 60 seconds into the past (exceeds default 30.0s window)
        let pastDate = Date().addingTimeInterval(-60.0)
        let cmd = CommandMessage(command: .lockScreen, timestamp: pastDate, validityWindowSeconds: 30.0)
        let envelope = try SecureChannel.seal(
            message: cmd,
            sequenceNumber: 1,
            senderIdentity: client,
            recipientPublicKeyHex: host.identity.publicKeyHex,
            sessionKey: sessionKey,
            referenceTime: pastDate
        )

        let framed = try NetworkFraming.frame(data: JSONEncoder().encode(envelope))
        let resp = try await sendRawData(framed, to: port)
        let ack = try JSONDecoder().decode(CommandAcknowledgment.self, from: resp)

        guard case .rejected(let reason) = ack.status else {
            XCTFail("Excessive clock skew must be rejected, got: \(ack.status)")
            return
        }
        XCTAssertTrue(reason.contains("Authentication failed") || reason.contains("clock"), "Reason: \(reason)")
    }

    // MARK: - Test 8: Out-of-Order Sequence Number Beyond Window

    func test08_OutOfOrderSequenceBeyondWindow() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "adv.host.08")
        let client = try makeClient(label: "adv.client.08")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "adv.ts.08")
        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }
        try await trustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.lockScreen],
            preSharedKeyHex: pskHex
        ))

        let serverCounter = SequenceCounter()
        // Fast forward server counter to sequence 2500 (beyond window size of 1000)
        _ = await serverCounter.validateAndAcceptIncoming(2500)

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore, sequenceCounter: serverCounter)
        try await server.start()

        let sessionKey = try SecureChannel.resolveSessionKey(preSharedKeyHex: pskHex, role: .clientToHost)

        // Send sequence number 50 (difference 2450 > window 1000)
        let cmd = CommandMessage(command: .lockScreen)
        let envelope = try SecureChannel.seal(
            message: cmd,
            sequenceNumber: 50,
            senderIdentity: client,
            recipientPublicKeyHex: host.identity.publicKeyHex,
            sessionKey: sessionKey
        )

        let framed = try NetworkFraming.frame(data: JSONEncoder().encode(envelope))
        let resp = try await sendRawData(framed, to: port)
        let ack = try JSONDecoder().decode(CommandAcknowledgment.self, from: resp)

        guard case .rejected(let reason) = ack.status else {
            XCTFail("Sequence number beyond sliding window must be rejected, got: \(ack.status)")
            return
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("replay") || reason.localizedCaseInsensitiveContains("sequence"), "Reason: \(reason)")
    }

    // MARK: - Test 9: Duplicate Command Message ID

    func test09_DuplicateCommandMessageIdHandling() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "adv.host.09")
        let client = try makeClient(label: "adv.client.09")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "adv.ts.09")
        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }
        try await trustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.lockScreen],
            preSharedKeyHex: pskHex
        ))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let sessionKey = try SecureChannel.resolveSessionKey(preSharedKeyHex: pskHex, role: .clientToHost)

        let fixedId = UUID()
        let cmd = CommandMessage(id: fixedId, command: .lockScreen)

        // Seal with sequence 1
        let env1 = try SecureChannel.seal(
            message: cmd,
            sequenceNumber: 1,
            senderIdentity: client,
            recipientPublicKeyHex: host.identity.publicKeyHex,
            sessionKey: sessionKey
        )
        let framed1 = try NetworkFraming.frame(data: JSONEncoder().encode(env1))
        let resp1 = try await sendRawData(framed1, to: port)
        let ack1 = try JSONDecoder().decode(CommandAcknowledgment.self, from: resp1)
        XCTAssertEqual(ack1.status, .executed)

        // Second packet with sequence 2 but same message ID
        let env2 = try SecureChannel.seal(
            message: cmd,
            sequenceNumber: 2,
            senderIdentity: client,
            recipientPublicKeyHex: host.identity.publicKeyHex,
            sessionKey: sessionKey
        )
        let framed2 = try NetworkFraming.frame(data: JSONEncoder().encode(env2))
        let resp2 = try await sendRawData(framed2, to: port)
        let ack2 = try JSONDecoder().decode(CommandAcknowledgment.self, from: resp2)
        // Handled cleanly by protocol: duplicate message ID rejected fail-closed
        XCTAssertEqual(ack2.commandId, fixedId)
        XCTAssertEqual(ack2.status, .rejected("Duplicate command request ID rejected."))
    }

    // MARK: - Test 10: Malformed Packet / Truncated JSON Framing

    func test10_MalformedPacketTruncatedJSONFraming() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "adv.host.10")
        let client = try makeClient(label: "adv.client.10")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "adv.ts.10")
        try await trustStore.addOrUpdate(TrustRecord(peer: client.identity, authorizedCapabilities: [.lockScreen]))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let corruptPayload = "{\"protocolVersion\": 1, \"senderPublicKeyHex\": \"ab".data(using: .utf8)!
        let framed = try NetworkFraming.frame(data: corruptPayload)

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "com.handshake.test.10", qos: .userInitiated)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                if case .ready = state { continuation.resume() }
                if case .failed(let err) = state { continuation.resume(throwing: err) }
            }
            connection.start(queue: queue)
        }

        // Send corrupt JSON frame
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { err in
                if let err = err { continuation.resume(throwing: err) } else { continuation.resume() }
            })
        }

        // Server must catch decoding error and close the connection without crashing
        try await Task.sleep(nanoseconds: 100_000_000)
        connection.cancel()
    }

    // MARK: - Test 11: Oversized Packet Exceeding 64 KB Limit

    func test11_OversizedPacketExceeding64KBLimit() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "adv.host.11")
        let client = try makeClient(label: "adv.client.11")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "adv.ts.11")
        try await trustStore.addOrUpdate(TrustRecord(peer: client.identity, authorizedCapabilities: [.lockScreen]))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "com.handshake.test.11", qos: .userInitiated)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                if case .ready = state { continuation.resume() }
                if case .failed(let err) = state { continuation.resume(throwing: err) }
            }
            connection.start(queue: queue)
        }

        // Send 4-byte header claiming 70,000 bytes (> 65,536 limit)
        var oversizedHeader = UInt32(70_000).bigEndian
        var rawHeader = Data()
        withUnsafeBytes(of: &oversizedHeader) { rawHeader.append(contentsOf: $0) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: rawHeader, completion: .contentProcessed { err in
                if let err = err { continuation.resume(throwing: err) } else { continuation.resume() }
            })
        }

        // Server should drop connection due to frameTooLarge without hanging
        try await Task.sleep(nanoseconds: 100_000_000)
        connection.cancel()
    }

    // MARK: - Test 12: Partial Packet Accumulation Over Stream

    func test12_PartialPacketAccumulationOverStream() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "adv.host.12")
        let client = try makeClient(label: "adv.client.12")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "adv.ts.12")
        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }
        try await trustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.lockScreen],
            preSharedKeyHex: pskHex
        ))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let sessionKey = try SecureChannel.resolveSessionKey(preSharedKeyHex: pskHex, role: .clientToHost)
        let cmd = CommandMessage(command: .lockScreen)
        let envelope = try SecureChannel.seal(
            message: cmd,
            sequenceNumber: 1,
            senderIdentity: client,
            recipientPublicKeyHex: host.identity.publicKeyHex,
            sessionKey: sessionKey
        )

        let framed = try NetworkFraming.frame(data: JSONEncoder().encode(envelope))

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "com.handshake.test.12", qos: .userInitiated)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                if case .ready = state { continuation.resume() }
                if case .failed(let err) = state { continuation.resume(throwing: err) }
            }
            connection.start(queue: queue)
        }

        // Send in small 15-byte fragments to simulate TCP fragmentation
        var offset = 0
        let chunkSize = 15
        while offset < framed.count {
            let nextEnd = min(offset + chunkSize, framed.count)
            let chunk = framed.subdata(in: offset..<nextEnd)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: chunk, completion: .contentProcessed { err in
                    if let err = err { continuation.resume(throwing: err) } else { continuation.resume() }
                })
            }
            offset = nextEnd
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms jitter between fragments
        }

        // Receive acknowledgment: server must successfully assemble the fragmented stream
        let respData = try await NetworkFraming.receive(from: connection)
        let ack = try JSONDecoder().decode(CommandAcknowledgment.self, from: respData)
        XCTAssertEqual(ack.status, .executed)
        connection.cancel()
    }

    // MARK: - Test 13: Interrupted Connection / Socket Closed Mid-Frame

    func test13_InterruptedConnectionSocketClosedMidFrame() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "adv.host.13")
        let client = try makeClient(label: "adv.client.13")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "adv.ts.13")
        try await trustStore.addOrUpdate(TrustRecord(peer: client.identity, authorizedCapabilities: [.lockScreen]))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "com.handshake.test.13", qos: .userInitiated)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                if case .ready = state { continuation.resume() }
                if case .failed(let err) = state { continuation.resume(throwing: err) }
            }
            connection.start(queue: queue)
        }

        // Send 4-byte header claiming 100 bytes
        var header = UInt32(100).bigEndian
        var headerData = Data()
        withUnsafeBytes(of: &header) { headerData.append(contentsOf: $0) }
        // Send only 5 bytes of the 100 bytes promised
        headerData.append(contentsOf: [0x01, 0x02, 0x03, 0x04, 0x05])

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: headerData, completion: .contentProcessed { err in
                if let err = err { continuation.resume(throwing: err) } else { continuation.resume() }
            })
        }

        // Abruptly terminate connection mid-frame
        connection.cancel()

        // Server handles premature EOF gracefully without crashing
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - Test 14: Connection Timeout Handling

    func test14_ConnectionTimeoutHandling() async throws {
        let deadPort: UInt16 = 5999 // Non-listening port
        let client = try makeClient(label: "adv.client.14")
        let host = try makeHost(label: "adv.host.14")

        let handshakeClient = HandshakeClient(clientIdentity: client)
        let deadEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: deadPort))

        do {
            _ = try await handshakeClient.sendCommand(
                .lockScreen,
                to: deadEndpoint,
                trustedHostPublicKeyHex: host.identity.publicKeyHex
            )
            XCTFail("Connecting to dead port must fail")
        } catch let err as HandshakeClient.ClientError {
            switch err {
            case .connectionFailed, .timeout:
                // Expected fail-closed behavior
                break
            default:
                XCTFail("Expected connection failure or timeout, got: \(err)")
            }
        }
    }

    // MARK: - Test 15: Multiple Simultaneous Clients Connected Concurrently

    func test15_MultipleSimultaneousClientsConcurrent() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "adv.host.15")
        let clientA = try makeClient(label: "adv.client.15a", name: "iPhone A")
        let clientB = try makeClient(label: "adv.client.15b", name: "iPhone B")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "adv.ts.15")
        let pskA = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }
        let pskB = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }

        try await trustStore.addOrUpdate(TrustRecord(peer: clientA.identity, authorizedCapabilities: [.lockScreen], preSharedKeyHex: pskA))
        try await trustStore.addOrUpdate(TrustRecord(peer: clientB.identity, authorizedCapabilities: [.lockScreen], preSharedKeyHex: pskB))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))
        let handshakeA = HandshakeClient(clientIdentity: clientA)
        let handshakeB = HandshakeClient(clientIdentity: clientB)

        // Dispatch simultaneously in parallel tasks
        async let taskA = handshakeA.sendCommand(
            .lockScreen,
            to: endpoint,
            trustedHostPublicKeyHex: host.identity.publicKeyHex,
            preSharedKeyHex: pskA
        )
        async let taskB = handshakeB.sendCommand(
            .lockScreen,
            to: endpoint,
            trustedHostPublicKeyHex: host.identity.publicKeyHex,
            preSharedKeyHex: pskB
        )

        let (ackA, ackB) = try await (taskA, taskB)
        XCTAssertEqual(ackA.status, .executed)
        XCTAssertEqual(ackB.status, .executed)
    }

    // MARK: - Test 16: Revoked Paired Device Rejection

    func test16_RevokedPairedDeviceRejection() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "adv.host.16")
        let client = try makeClient(label: "adv.client.16")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "adv.ts.16")
        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }

        // Paired, but REVOKED
        try await trustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            isRevoked: true,
            authorizedCapabilities: [.lockScreen],
            preSharedKeyHex: pskHex
        ))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let handshakeClient = HandshakeClient(clientIdentity: client)
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))

        do {
            _ = try await handshakeClient.sendCommand(
                .lockScreen,
                to: endpoint,
                trustedHostPublicKeyHex: host.identity.publicKeyHex,
                preSharedKeyHex: pskHex
            )
            XCTFail("Revoked device must be rejected")
        } catch let err as HandshakeClient.ClientError {
            guard case .commandRejected(let reason) = err else {
                XCTFail("Expected commandRejected error, got: \(err)")
                return
            }
            XCTAssertTrue(reason.contains("revoked"), "Reason was: \(reason)")
        }
    }

    // MARK: - Test 17: Multi-Message Session Sequential Execution

    func test17_MultiMessageSessionSequentialExecution() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "adv.host.17")
        let client = try makeClient(label: "adv.client.17")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "adv.ts.17")
        let pskHex = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hexString }

        try await trustStore.addOrUpdate(TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.lockScreen, .sleep, .ping],
            preSharedKeyHex: pskHex
        ))

        let collector = CommandCollector()
        let server = makeSafeServer(
            port: port,
            host: host,
            trustStore: trustStore,
            executionHandler: { message, peer in
                collector.append(message.command)
                return .executed
            }
        )
        try await server.start()

        let handshakeClient = HandshakeClient(clientIdentity: client)
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))

        // Open single persistent TCP session
        let session = try await handshakeClient.openSession(
            to: endpoint,
            trustedHost: host.identity,
            preSharedKeyHex: pskHex
        )

        // Command 1: ping
        let ack1 = try await session.sendCommand(.ping)
        XCTAssertEqual(ack1.status, .executed)

        // Command 2: lockScreen over same socket
        let ack2 = try await session.sendCommand(.lockScreen)
        XCTAssertEqual(ack2.status, .executed)

        session.close()

        XCTAssertEqual(collector.all, [.ping, .lockScreen])
    }
}

private final class CommandCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [CommandType] = []

    func append(_ cmd: CommandType) {
        lock.lock()
        defer { lock.unlock() }
        commands.append(cmd)
    }

    var all: [CommandType] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }
}
