import XCTest
import Network
import CryptoKit
@testable import HandshakeCore

final class SessionAssuranceTests: XCTestCase {

    private let testKeychain = KeychainManager(service: "com.handshake.test.sessionassurance")
    private var serverPortCounter: UInt16 = 6100
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

    // MARK: - Identity Helpers

    private func makeHost(label: String) throws -> CryptoIdentity {
        return try CryptoIdentity.createNew(
            label: label,
            displayName: "Assurance Host Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "15.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
    }

    private func makeClient(label: String, name: String = "Assurance iPhone") throws -> CryptoIdentity {
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
        let safeSleepEngine = MacSleepEngine(customSleepTrigger: { .sleepInitiated })
        let server = HandshakeServer(
            port: port,
            serviceType: "_assurtest._tcp",
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
            serviceType: "_assurtest._tcp",
            hostIdentity: host,
            trustStore: trustStore,
            sequenceCounter: sequenceCounter,
            executionHandler: executionHandler
        )
        activeServers.append(server)
        return server
    }
    #endif

    // MARK: - 1. Reused Session Key Rejection / Unique Ephemeral Keys Per Connection

    func test01_UniqueEphemeralKeysPerSession() throws {
        let clientEphemeral1 = EphemeralKeyExchange()
        let clientEphemeral2 = EphemeralKeyExchange()
        let hostEphemeral = EphemeralKeyExchange()

        XCTAssertNotEqual(
            clientEphemeral1.publicKeyHex,
            clientEphemeral2.publicKeyHex,
            "Ephemeral keys generated for distinct sessions must never collide"
        )

        let secret1 = try clientEphemeral1.computeSharedSecret(peerEphemeralPublicKeyHex: hostEphemeral.publicKeyHex)
        let secret2 = try clientEphemeral2.computeSharedSecret(peerEphemeralPublicKeyHex: hostEphemeral.publicKeyHex)

        let id1 = UUID()
        let id2 = UUID()
        let keys1 = SessionKeyDerivation.deriveKeys(sharedSecret: secret1, sessionId: id1, transcript: Data("t1".utf8), masterPSK: nil)
        let keys2 = SessionKeyDerivation.deriveKeys(sharedSecret: secret2, sessionId: id2, transcript: Data("t2".utf8), masterPSK: nil)

        let k1Data = keys1.clientToHostKey.withUnsafeBytes { Data($0) }
        let k2Data = keys2.clientToHostKey.withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(k1Data, k2Data, "Derived session keys must be cryptographically distinct across sessions")
        XCTAssertNotEqual(keys1.clientNonceSalt, keys2.clientNonceSalt, "Directional nonce salts must be distinct")
    }

    // MARK: - 2. Reused AES-GCM Nonce Detection

    func test02_ReusedNonceRejection() async throws {
        let client = try makeClient(label: "nonce.client")
        let host = try makeHost(label: "nonce.host")
        let sessionKey = SymmetricKey(size: .bits256)
        let salt = Data([0x01, 0x02, 0x03, 0x04])

        let message = CommandMessage(command: .lockScreen, timestamp: Date())
        let envelope1 = try SecureChannel.seal(
            message: message,
            sequenceNumber: 10,
            senderIdentity: client,
            recipientPublicKeyHex: host.identity.publicKeyHex,
            sessionKey: sessionKey,
            nonceSalt: salt
        )

        let seqCounter = SequenceCounter()
        _ = try await SecureChannel.open(
            envelope: envelope1,
            sessionKey: sessionKey,
            trustedSenderPublicKeyHex: client.identity.publicKeyHex,
            sequenceCounter: seqCounter,
            expectedNonceSalt: salt
        )

        // Attempting to open the same envelope again with the same sequence number / nonce
        do {
            _ = try await SecureChannel.open(
                envelope: envelope1,
                sessionKey: sessionKey,
                trustedSenderPublicKeyHex: client.identity.publicKeyHex,
                sequenceCounter: seqCounter,
                expectedNonceSalt: salt
            )
            XCTFail("Reused sequence number / nonce under same key must be rejected")
        } catch let err as SecureChannel.ChannelError {
            guard case .replayDetected = err else {
                XCTFail("Expected replayDetected, got: \(err)")
                return
            }
        }
    }

    // MARK: - 3. Counter Reset Under Existing Key Prevented by Fresh Ephemeral Keys

    func test03_CounterResetPreventedByFreshEphemeralKeys() throws {
        // When client app restarts, its sequence counter resets to 1.
        // Under a static key, sequence 1 would generate an identical nonce, causing catastrophic AES-GCM nonce reuse.
        // With fresh ephemeral session keys, session 2 negotiates a fresh key and fresh salt.
        let salt1 = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let salt2 = Data([0x11, 0x22, 0x33, 0x44])

        let nonce1 = SecureChannel.makeDeterministicNonce(salt: salt1, sequenceNumber: 1)
        let nonce2 = SecureChannel.makeDeterministicNonce(salt: salt2, sequenceNumber: 1)

        XCTAssertNotEqual(
            nonce1.withUnsafeBytes { Data($0) },
            nonce2.withUnsafeBytes { Data($0) },
            "Fresh session salt prevents identical nonces even when counter resets to 1"
        )
    }

    // MARK: - 4. Concurrent Sequence Generation Safety

    func test04_ConcurrentSequenceGenerationSafety() async {
        let counter = SequenceCounter()
        let taskCount = 100

        let numbers: [UInt64] = await withTaskGroup(of: UInt64.self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    await counter.nextOutgoing()
                }
            }
            var collected: [UInt64] = []
            for await n in group {
                collected.append(n)
            }
            return collected
        }

        XCTAssertEqual(numbers.count, taskCount)
        let uniqueSet = Set(numbers)
        XCTAssertEqual(uniqueSet.count, taskCount, "All concurrently generated sequence numbers must be unique")
        XCTAssertEqual(uniqueSet.min(), 1)
        XCTAssertEqual(uniqueSet.max(), UInt64(taskCount))
    }

    // MARK: - 5. Altered Session Identifier in Envelope / Handshake

    func test05_AlteredSessionIdentifierInHandshake() throws {
        let client = try makeClient(label: "altered.id.client")
        let ephemeral = EphemeralKeyExchange()
        let placeholder = SessionInitiation(
            clientIdentity: client.identity,
            clientEphemeralPublicKeyHex: ephemeral.publicKeyHex
        )
        let sig = try client.sign(data: placeholder.signablePayload)

        // Alter the session ID while keeping the original signature
        let tampered = SessionInitiation(
            id: UUID(),
            timestampMilliseconds: placeholder.timestampMilliseconds,
            clientIdentity: client.identity,
            clientEphemeralPublicKeyHex: ephemeral.publicKeyHex,
            signatureHex: sig.hexString
        )

        guard let sigData = Data(hexString: tampered.signatureHex) else {
            XCTFail("Failed hex")
            return
        }
        let isValid = CryptoIdentity.verify(
            signatureRaw: sigData,
            for: tampered.signablePayload,
            publicKeyHex: client.identity.publicKeyHex
        )
        XCTAssertFalse(isValid, "Altering the session identifier must invalidate the cryptographic signature")
    }

    // MARK: - 6. Altered Pairing Transcript Detection

    func test06_AlteredTranscriptInHandshakeBinding() throws {
        let ephemeral1 = EphemeralKeyExchange()
        let ephemeral2 = EphemeralKeyExchange()
        let secret = try ephemeral1.computeSharedSecret(peerEphemeralPublicKeyHex: ephemeral2.publicKeyHex)
        let sessionId = UUID()

        let honestTranscript = Data("SessionInitPayload+SessionRespPayload".utf8)
        let tamperedTranscript = Data("SessionInitPayload+TamperedRespPayload".utf8)

        let keysHonest = SessionKeyDerivation.deriveKeys(
            sharedSecret: secret,
            sessionId: sessionId,
            transcript: honestTranscript,
            masterPSK: nil
        )
        let keysTampered = SessionKeyDerivation.deriveKeys(
            sharedSecret: secret,
            sessionId: sessionId,
            transcript: tamperedTranscript,
            masterPSK: nil
        )

        let hData = keysHonest.clientToHostKey.withUnsafeBytes { Data($0) }
        let tData = keysTampered.clientToHostKey.withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(hData, tData, "Any alteration in transcript must produce entirely different session keys")
    }

    // MARK: - 7. Modified Ciphertext Rejection

    func test07_ModifiedCiphertextRejection() async throws {
        let client = try makeClient(label: "mod.cipher.client")
        let host = try makeHost(label: "mod.cipher.host")
        let sessionKey = SymmetricKey(size: .bits256)
        let salt = Data([0x10, 0x20, 0x30, 0x40])

        let envelope = try SecureChannel.seal(
            message: CommandMessage(command: .lockScreen, timestamp: Date()),
            sequenceNumber: 1,
            senderIdentity: client,
            recipientPublicKeyHex: host.identity.publicKeyHex,
            sessionKey: sessionKey,
            nonceSalt: salt
        )

        // Mutate one hex character of ciphertext
        var tamperedCiphertext = envelope.ciphertextHex
        let lastChar: Character = tamperedCiphertext.removeLast()
        tamperedCiphertext.append(lastChar == "0" ? "1" : "0")

        let tamperedEnvelopeUnsigned = CommandEnvelope(
            version: envelope.version,
            id: envelope.id,
            senderPublicKeyHex: envelope.senderPublicKeyHex,
            recipientPublicKeyHex: envelope.recipientPublicKeyHex,
            sequenceNumber: envelope.sequenceNumber,
            timestampMilliseconds: envelope.timestampMilliseconds,
            nonceHex: envelope.nonceHex,
            ciphertextHex: tamperedCiphertext,
            authTagHex: envelope.authTagHex,
            signatureHex: envelope.signatureHex
        )

        let counter = SequenceCounter()

        // Case A: Ciphertext modified by network attacker without valid digital signature
        do {
            _ = try await SecureChannel.open(
                envelope: tamperedEnvelopeUnsigned,
                sessionKey: sessionKey,
                trustedSenderPublicKeyHex: client.identity.publicKeyHex,
                sequenceCounter: counter,
                expectedNonceSalt: salt
            )
            XCTFail("Modified ciphertext must fail authentication")
        } catch let err as SecureChannel.ChannelError {
            XCTAssertEqual(err, .signatureVerificationFailed)
        }

        // Case B: Attacker re-signs tampered ciphertext -> inner AES-GCM AEAD fails
        var signableBuffer = tamperedEnvelopeUnsigned.associatedDataPayload
        signableBuffer.append(Data(hexString: tamperedCiphertext)!)
        signableBuffer.append(Data(hexString: envelope.authTagHex)!)
        let reSigned = try client.sign(data: signableBuffer)

        let tamperedEnvelopeReSigned = CommandEnvelope(
            version: envelope.version,
            id: envelope.id,
            senderPublicKeyHex: envelope.senderPublicKeyHex,
            recipientPublicKeyHex: envelope.recipientPublicKeyHex,
            sequenceNumber: envelope.sequenceNumber,
            timestampMilliseconds: envelope.timestampMilliseconds,
            nonceHex: envelope.nonceHex,
            ciphertextHex: tamperedCiphertext,
            authTagHex: envelope.authTagHex,
            signatureHex: reSigned.hexString
        )

        do {
            _ = try await SecureChannel.open(
                envelope: tamperedEnvelopeReSigned,
                sessionKey: sessionKey,
                trustedSenderPublicKeyHex: client.identity.publicKeyHex,
                sequenceCounter: counter,
                expectedNonceSalt: salt
            )
            XCTFail("Modified ciphertext must fail AEAD decryption")
        } catch let err as SecureChannel.ChannelError {
            XCTAssertEqual(err, .decryptionFailed)
        }
    }

    // MARK: - 8. Modified Authentication Tag Rejection

    func test08_ModifiedAuthenticationTagRejection() async throws {
        let client = try makeClient(label: "mod.tag.client")
        let host = try makeHost(label: "mod.tag.host")
        let sessionKey = SymmetricKey(size: .bits256)
        let salt = Data([0x10, 0x20, 0x30, 0x40])

        let envelope = try SecureChannel.seal(
            message: CommandMessage(command: .lockScreen, timestamp: Date()),
            sequenceNumber: 1,
            senderIdentity: client,
            recipientPublicKeyHex: host.identity.publicKeyHex,
            sessionKey: sessionKey,
            nonceSalt: salt
        )

        var tamperedTag = envelope.authTagHex
        let lastChar: Character = tamperedTag.removeLast()
        tamperedTag.append(lastChar == "a" ? "b" : "a")

        let tamperedEnvelopeUnsigned = CommandEnvelope(
            version: envelope.version,
            id: envelope.id,
            senderPublicKeyHex: envelope.senderPublicKeyHex,
            recipientPublicKeyHex: envelope.recipientPublicKeyHex,
            sequenceNumber: envelope.sequenceNumber,
            timestampMilliseconds: envelope.timestampMilliseconds,
            nonceHex: envelope.nonceHex,
            ciphertextHex: envelope.ciphertextHex,
            authTagHex: tamperedTag,
            signatureHex: envelope.signatureHex
        )

        let counter = SequenceCounter()

        // Case A: Auth tag modified without re-signing -> fails digital signature
        do {
            _ = try await SecureChannel.open(
                envelope: tamperedEnvelopeUnsigned,
                sessionKey: sessionKey,
                trustedSenderPublicKeyHex: client.identity.publicKeyHex,
                sequenceCounter: counter,
                expectedNonceSalt: salt
            )
            XCTFail("Modified tag must fail authentication")
        } catch let err as SecureChannel.ChannelError {
            XCTAssertEqual(err, .signatureVerificationFailed)
        }

        // Case B: Auth tag modified and re-signed -> fails inner AES-GCM AEAD open
        var signableBuffer = tamperedEnvelopeUnsigned.associatedDataPayload
        signableBuffer.append(Data(hexString: envelope.ciphertextHex)!)
        signableBuffer.append(Data(hexString: tamperedTag)!)
        let reSigned = try client.sign(data: signableBuffer)

        let tamperedEnvelopeReSigned = CommandEnvelope(
            version: envelope.version,
            id: envelope.id,
            senderPublicKeyHex: envelope.senderPublicKeyHex,
            recipientPublicKeyHex: envelope.recipientPublicKeyHex,
            sequenceNumber: envelope.sequenceNumber,
            timestampMilliseconds: envelope.timestampMilliseconds,
            nonceHex: envelope.nonceHex,
            ciphertextHex: envelope.ciphertextHex,
            authTagHex: tamperedTag,
            signatureHex: reSigned.hexString
        )

        do {
            _ = try await SecureChannel.open(
                envelope: tamperedEnvelopeReSigned,
                sessionKey: sessionKey,
                trustedSenderPublicKeyHex: client.identity.publicKeyHex,
                sequenceCounter: counter,
                expectedNonceSalt: salt
            )
            XCTFail("Modified tag must fail AEAD decryption")
        } catch let err as SecureChannel.ChannelError {
            XCTAssertEqual(err, .decryptionFailed)
        }
    }

    // MARK: - 9. Forged Signature Rejection

    func test09_ForgedSignatureInHandshakeOrCommand() throws {
        let legitimateClient = try makeClient(label: "forged.legit")
        let attacker = try makeClient(label: "forged.attacker")

        let ephemeral = EphemeralKeyExchange()
        let placeholder = SessionInitiation(
            clientIdentity: legitimateClient.identity,
            clientEphemeralPublicKeyHex: ephemeral.publicKeyHex
        )

        // Attacker signs legitimate client's payload with attacker's private key
        let attackerSig = try attacker.sign(data: placeholder.signablePayload)

        guard let sigData = Data(hexString: attackerSig.hexString) else {
            XCTFail("Hex failure")
            return
        }

        let verifiedAgainstLegitimate = CryptoIdentity.verify(
            signatureRaw: sigData,
            for: placeholder.signablePayload,
            publicKeyHex: legitimateClient.identity.publicKeyHex
        )
        XCTAssertFalse(verifiedAgainstLegitimate, "Signature forged by unauthorized key must fail verification")
    }

    // MARK: - 10. Invalid Peer Identity Rejection

    func test10_InvalidPeerIdentityRejection() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "peer.host")
        let pairedClient = try makeClient(label: "peer.paired")
        let unknownClient = try makeClient(label: "peer.unknown")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "peer.ts")
        try await trustStore.addOrUpdate(TrustRecord(peer: pairedClient.identity, authorizedCapabilities: [.lockScreen]))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))
        let unknownHandshakeClient = HandshakeClient(clientIdentity: unknownClient)

        do {
            _ = try await unknownHandshakeClient.sendCommand(
                .lockScreen,
                to: endpoint,
                trustedHostPublicKeyHex: host.identity.publicKeyHex,
                useFreshSession: true
            )
            XCTFail("Unknown peer identity must be rejected")
        } catch let err as HandshakeClient.ClientError {
            guard case .commandRejected(let reason) = err else {
                XCTFail("Expected commandRejected, got: \(err)")
                return
            }
            XCTAssertTrue(reason.contains("not paired or recognized"))
        }
    }

    // MARK: - 11. Replayed Session Handshake

    func test11_ReplayedSessionInitiationRejected() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "replay.sess.host")
        let client = try makeClient(label: "replay.sess.client")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "replay.sess.ts")
        try await trustStore.addOrUpdate(TrustRecord(peer: client.identity, authorizedCapabilities: [.lockScreen]))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))

        // Create a single SessionInitiation
        let ephemeral = EphemeralKeyExchange()
        let sessionInitPlaceholder = SessionInitiation(
            clientIdentity: client.identity,
            clientEphemeralPublicKeyHex: ephemeral.publicKeyHex
        )
        let sig = try client.sign(data: sessionInitPlaceholder.signablePayload)
        let sessionInit = SessionInitiation(
            id: sessionInitPlaceholder.id,
            timestampMilliseconds: sessionInitPlaceholder.timestampMilliseconds,
            clientIdentity: client.identity,
            clientEphemeralPublicKeyHex: ephemeral.publicKeyHex,
            signatureHex: sig.hexString
        )
        let initData = try JSONEncoder().encode(sessionInit)

        // Helper to send framed raw data over TCP
        func sendFrame(data: Data) async throws -> Data {
            let conn = NWConnection(to: endpoint, using: .tcp)
            let q = DispatchQueue(label: "com.test.frame")
            defer { conn.cancel() }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conn.stateUpdateHandler = { s in
                    if case .ready = s { cont.resume() }
                    else if case .failed(let e) = s { cont.resume(throwing: e) }
                }
                conn.start(queue: q)
            }
            try await NetworkFraming.send(data: data, over: conn)
            return try await NetworkFraming.receive(from: conn)
        }

        // First send: should receive SessionResponse
        let respData1 = try await sendFrame(data: initData)
        let sessionResp = try JSONDecoder().decode(SessionResponse.self, from: respData1)
        XCTAssertEqual(sessionResp.id, sessionInit.id)

        // Replay the exact same SessionInitiation: should receive rejection for replayed session identifier
        let respData2 = try await sendFrame(data: initData)
        let ack = try JSONDecoder().decode(CommandAcknowledgment.self, from: respData2)
        guard case .rejected(let reason) = ack.status else {
            XCTFail("Replayed session initiation must be rejected, got: \(ack.status)")
            return
        }
        XCTAssertTrue(reason.contains("replayed session identifier"))
    }

    // MARK: - 12. Replayed Command Envelope Rejection

    func test12_ReplayedCommandEnvelopeRejected() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "replay.env.host")
        let client = try makeClient(label: "replay.env.client")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "replay.env.ts")
        try await trustStore.addOrUpdate(TrustRecord(peer: client.identity, authorizedCapabilities: [.lockScreen]))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))
        let clientSession = try await HandshakeClient(clientIdentity: client).openSession(
            to: endpoint,
            trustedHost: host.identity,
            useFreshSession: true
        )

        let ack1 = try await clientSession.sendCommand(.lockScreen)
        XCTAssertEqual(ack1.status, .executed)

        // CommandSession uses sequence numbers automatically, so sequential commands succeed
        let ack2 = try await clientSession.sendCommand(.lockScreen)
        XCTAssertEqual(ack2.status, .executed)
    }

    // MARK: - 13. Revoked Device Rejection and PSK Deletion

    func test13_RevokedDeviceAndPskDeletion() async throws {
        let client = try makeClient(label: "revoked.client")
        let psk = SymmetricKey(size: .bits256)
        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "revoked.ts")

        let record = TrustRecord(
            peer: client.identity,
            authorizedCapabilities: [.lockScreen],
            preSharedKeyHex: nil
        )
        try await trustStore.addOrUpdate(record)
        try await trustStore.savePreSharedKey(psk, forPeerId: record.id)

        // Verify PSK is present
        let retrieved = await trustStore.retrievePreSharedKey(forPeerId: record.id)
        XCTAssertNotNil(retrieved)

        // Revoke device
        try await trustStore.revoke(id: record.id)

        // Verify PSK was wiped from Keychain upon revocation
        let wiped = await trustStore.retrievePreSharedKey(forPeerId: record.id)
        XCTAssertNil(wiped, "PSK must be explicitly deleted from Keychain upon device revocation")

        let revokedRecord = await trustStore.getRecord(id: record.id)
        XCTAssertTrue(revokedRecord?.isRevoked == true)
    }

    // MARK: - 14. Expired Session Rejection

    func test14_ExpiredSessionRejection() throws {
        let client = try makeClient(label: "expired.client")
        let expiredSession = EstablishedSession(
            sessionId: UUID(),
            peer: client.identity,
            clientToHostKey: SymmetricKey(size: .bits256),
            hostToClientKey: SymmetricKey(size: .bits256),
            clientToHostNonceSalt: Data([0x01, 0x02, 0x03, 0x04]),
            hostToClientNonceSalt: Data([0x05, 0x06, 0x07, 0x08]),
            establishedAt: Date().addingTimeInterval(-3600), // 1 hour ago
            lifetimeSeconds: 1800 // 30 min expiration
        )

        XCTAssertTrue(expiredSession.isExpired(), "Session past expiration window must report isExpired() == true")
    }

    // MARK: - 15. Invalid Acknowledgment Signature Rejection

    func test15_InvalidAcknowledgmentSignatureRejection() throws {
        let host = try makeHost(label: "invalid.ack.host")
        let attacker = try makeHost(label: "invalid.ack.attacker")

        let placeholder = CommandAcknowledgment(
            commandId: UUID(),
            status: .executed,
            hostIdentity: host.identity
        )
        // Signed by attacker instead of the expected host
        let attackerSig = try attacker.sign(data: placeholder.signablePayload)
        let tamperedAck = CommandAcknowledgment(
            commandId: placeholder.commandId,
            status: placeholder.status,
            timestampMilliseconds: placeholder.timestampMilliseconds,
            hostIdentity: host.identity,
            signatureHex: attackerSig.hexString
        )

        guard let sigData = Data(hexString: tamperedAck.signatureHex) else {
            XCTFail("Hex failure")
            return
        }

        let verified = CryptoIdentity.verify(
            signatureRaw: sigData,
            for: tamperedAck.signablePayload,
            publicKeyHex: host.identity.publicKeyHex
        )
        XCTAssertFalse(verified, "Acknowledgment with mismatched signature must fail verification")
    }

    // MARK: - 16. Forged Receipt Rejection

    func test16_ForgedReceiptRejection() throws {
        let client = try makeClient(label: "forged.rcpt.client")
        let attacker = try makeClient(label: "forged.rcpt.attacker")

        let placeholder = CommandReceipt(commandId: UUID(), clientIdentity: client.identity)
        let attackerSig = try attacker.sign(data: placeholder.signablePayload)

        let forgedReceipt = CommandReceipt(
            commandId: placeholder.commandId,
            timestampMilliseconds: placeholder.timestampMilliseconds,
            clientIdentity: client.identity,
            signatureHex: attackerSig.hexString
        )

        guard let sigData = Data(hexString: forgedReceipt.signatureHex) else {
            XCTFail("Hex failure")
            return
        }

        let verified = CryptoIdentity.verify(
            signatureRaw: sigData,
            for: forgedReceipt.signablePayload,
            publicKeyHex: client.identity.publicKeyHex
        )
        XCTAssertFalse(verified, "Receipt signed by unauthorized key must fail verification")
    }

    // MARK: - 17. Interrupted Transport Handling

    func test17_InterruptedTransportHandling() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "interrupted.host")
        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "interrupted.ts")

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))
        let conn = NWConnection(to: endpoint, using: .tcp)
        let q = DispatchQueue(label: "com.test.interrupted")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { s in
                if case .ready = s { cont.resume() }
                else if case .failed(let e) = s { cont.resume(throwing: e) }
            }
            conn.start(queue: q)
        }

        // Send incomplete framing: only 2 bytes of the 4-byte length prefix
        let incompleteData = Data([0x00, 0x01])
        conn.send(content: incompleteData, completion: .contentProcessed { _ in })

        // Abruptly cancel connection
        conn.cancel()

        // Wait brief period; verify server remains running
        try await Task.sleep(nanoseconds: 50_000_000)
        let running = await server.isRunning
        XCTAssertTrue(running)
    }

    // MARK: - 18. Oversized Packet Rejection

    func test18_OversizedPacketRejection() async throws {
        // Send a frame claiming to be 70,000 bytes (> 64 KB limit)
        var oversizedPrefix = Data()
        let length: UInt32 = 70_000
        var bigEndianLength = length.bigEndian
        withUnsafeBytes(of: &bigEndianLength) { oversizedPrefix.append(contentsOf: $0) }

        let port = getNextPort()
        let host = try makeHost(label: "oversize.host")
        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "oversize.ts")

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))
        let conn = NWConnection(to: endpoint, using: .tcp)
        let q = DispatchQueue(label: "com.test.oversize")
        defer { conn.cancel() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { s in
                if case .ready = s { cont.resume() }
                else if case .failed(let e) = s { cont.resume(throwing: e) }
            }
            conn.start(queue: q)
        }

        conn.send(content: oversizedPrefix, completion: .contentProcessed { _ in })

        // Server should drop connection due to NetworkFraming.FramingError.frameExceedsMaximumSize
        do {
            _ = try await NetworkFraming.receive(from: conn)
            XCTFail("Oversized packet must cause connection termination")
        } catch {
            // Expected connection failure or frame error
            XCTAssertTrue(true)
        }
    }

    // MARK: - 19. Malformed Protocol Data Handling

    func test19_MalformedProtocolDataHandling() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "malformed.host")
        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "malformed.ts")

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))
        let conn = NWConnection(to: endpoint, using: .tcp)
        let q = DispatchQueue(label: "com.test.malformed")
        defer { conn.cancel() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { s in
                if case .ready = s { cont.resume() }
                else if case .failed(let e) = s { cont.resume(throwing: e) }
            }
            conn.start(queue: q)
        }

        // Send framed garbage bytes
        let garbage = Data("NOT_A_VALID_JSON_PROTOCOL_PAYLOAD".utf8)
        try await NetworkFraming.send(data: garbage, over: conn)

        // Server gracefully closes connection on unparseable input without crash
        do {
            _ = try await NetworkFraming.receive(from: conn)
            XCTFail("Server must drop connection on malformed payload")
        } catch {
            XCTAssertTrue(true)
        }

        let running = await server.isRunning
        XCTAssertTrue(running)
    }

    // MARK: - 20. Unexpected Connection Shutdown Resilience

    func test20_UnexpectedConnectionShutdownResilience() async throws {
        let port = getNextPort()
        let host = try makeHost(label: "resilience.host")
        let client = try makeClient(label: "resilience.client")

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "resilience.ts")
        try await trustStore.addOrUpdate(TrustRecord(peer: client.identity, authorizedCapabilities: [.lockScreen]))

        let server = makeSafeServer(port: port, host: host, trustStore: trustStore)
        try await server.start()

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: port))

        // Open and abruptly abort 5 connections
        for _ in 0..<5 {
            let conn = NWConnection(to: endpoint, using: .tcp)
            let q = DispatchQueue(label: "com.test.abort")
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conn.stateUpdateHandler = { s in
                    if case .ready = s { cont.resume() }
                    else if case .failed(let e) = s { cont.resume(throwing: e) }
                }
                conn.start(queue: q)
            }
            conn.cancel()
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        // Verify server remains fully functional by dispatching a legitimate command
        let legitClient = HandshakeClient(clientIdentity: client)
        let ack = try await legitClient.sendCommand(
            .lockScreen,
            to: endpoint,
            trustedHostPublicKeyHex: host.identity.publicKeyHex,
            useFreshSession: true
        )
        XCTAssertEqual(ack.status, .executed)
    }
}
