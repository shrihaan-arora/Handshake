import XCTest
import CoreBluetooth
import CryptoKit
@testable import HandshakeCore

final class BLETransportTests: XCTestCase {

    // MARK: - Constants and Error Tests

    func testBLEConstantsUUIDs() {
        XCTAssertEqual(BLEConstants.serviceUUID.uuidString, "A67D5894-0409-411B-8233-000000000001")
        XCTAssertEqual(BLEConstants.commandCharacteristicUUID.uuidString, "A67D5894-0409-411B-8233-000000000002")
        XCTAssertEqual(BLEConstants.ackCharacteristicUUID.uuidString, "A67D5894-0409-411B-8233-000000000003")
        XCTAssertEqual(BLEConstants.maxChunkSize, 180)
    }

    func testBLETransportErrorDescriptions() {
        let poweredOff = BLETransportError.bluetoothPoweredOff
        let unauthorized = BLETransportError.bluetoothUnauthorized
        let unsupported = BLETransportError.bluetoothUnsupported
        let timedOut = BLETransportError.scanningTimedOut
        let invalidAck = BLETransportError.invalidAcknowledgment

        XCTAssertTrue(poweredOff.localizedDescription.contains("Bluetooth is turned off"))
        XCTAssertTrue(unauthorized.localizedDescription.contains("permission has not been granted"))
        XCTAssertTrue(unsupported.localizedDescription.contains("not supported"))
        XCTAssertTrue(timedOut.localizedDescription.contains("timed out"))
        XCTAssertTrue(invalidAck.localizedDescription.contains("digital signature"))
    }

    // MARK: - Framing Roundtrip Tests

    func testBLEPacketFramingSmallPayloadRoundtrip() throws {
        let payload = "Hello, secure BLE world!".data(using: .utf8)!
        let chunks = try BLEPacketFraming.chunk(frame: payload, maxChunkSize: 180)

        XCTAssertEqual(chunks.count, 1) // fits in one chunk
        let reassembler = BLEPacketFraming.Reassembler()
        let result = try reassembler.processChunk(chunks[0])
        XCTAssertNotNil(result)
        XCTAssertEqual(result, payload)
    }

    func testBLEPacketFramingMultiChunkRoundtrip() throws {
        // Generate a 4,500 byte random payload to require ~26 chunks at 180 bytes
        var randomBytes = [UInt8](repeating: 0, count: 4500)
        _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        let payload = Data(randomBytes)

        let chunkSize = 180
        let chunks = try BLEPacketFraming.chunk(frame: payload, maxChunkSize: chunkSize)
        XCTAssertGreaterThan(chunks.count, 20)

        let reassembler = BLEPacketFraming.Reassembler()
        var assembled: Data? = nil

        for (index, chunk) in chunks.enumerated() {
            let res = try reassembler.processChunk(chunk)
            if index == chunks.count - 1 {
                assembled = res
            } else {
                XCTAssertNil(res, "Intermediate chunk \(index) should not return assembled data")
            }
        }

        XCTAssertEqual(assembled, payload)
    }

    func testBLEPacketFramingEmptyPayload() throws {
        let payload = Data()
        let chunks = try BLEPacketFraming.chunk(frame: payload, maxChunkSize: 180)
        XCTAssertEqual(chunks.count, 1)

        let reassembler = BLEPacketFraming.Reassembler()
        let assembled = try reassembler.processChunk(chunks[0])
        XCTAssertNotNil(assembled)
        XCTAssertEqual(assembled?.count, 0)
    }

    func testBLEPacketFramingCustomSmallMTU() throws {
        let payload = Data(repeating: 0x42, count: 250)
        let chunkSize = 25 // Very constrained MTU
        let chunks = try BLEPacketFraming.chunk(frame: payload, maxChunkSize: chunkSize)

        let reassembler = BLEPacketFraming.Reassembler()
        var assembled: Data? = nil
        for chunk in chunks {
            if let result = try reassembler.processChunk(chunk) {
                assembled = result
            }
        }

        XCTAssertEqual(assembled, payload)
    }

    // MARK: - Framing Error & Boundary Tests

    func testBLEPacketFramingOversizedPayloadRejection() {
        let oversized = Data(repeating: 0xAA, count: BLEPacketFraming.maximumPayloadLength + 1)
        XCTAssertThrowsError(try BLEPacketFraming.chunk(frame: oversized, maxChunkSize: 180)) { error in
            guard case BLEPacketFraming.FramingError.payloadTooLarge(let size) = error else {
                XCTFail("Expected payloadTooLarge, got \(error)")
                return
            }
            XCTAssertEqual(size, BLEPacketFraming.maximumPayloadLength + 1)
        }
    }

    func testBLEPacketFramingOutOfOrderRejection() throws {
        let payload = Data(repeating: 0x55, count: 500)
        let chunks = try BLEPacketFraming.chunk(frame: payload, maxChunkSize: 100)
        XCTAssertGreaterThan(chunks.count, 2)

        let reassembler = BLEPacketFraming.Reassembler()
        // Feed chunk 0 (start)
        _ = try reassembler.processChunk(chunks[0])

        // Feed chunk 2 instead of chunk 1 (out of order skip)
        XCTAssertThrowsError(try reassembler.processChunk(chunks[2])) { error in
            guard case BLEPacketFraming.FramingError.outOfOrderChunk(let exp, let rec) = error else {
                XCTFail("Expected outOfOrderChunk, got \(error)")
                return
            }
            XCTAssertEqual(exp, 1)
            XCTAssertEqual(rec, 2)
        }
    }

    func testBLEPacketFramingDuplicateChunkRejection() throws {
        let payload = Data(repeating: 0x77, count: 500)
        let chunks = try BLEPacketFraming.chunk(frame: payload, maxChunkSize: 100)
        XCTAssertGreaterThan(chunks.count, 2)

        let reassembler = BLEPacketFraming.Reassembler()
        _ = try reassembler.processChunk(chunks[0])
        _ = try reassembler.processChunk(chunks[1])

        // Re-feed chunk 1 (duplicate continuation chunk)
        XCTAssertThrowsError(try reassembler.processChunk(chunks[1])) { error in
            guard case BLEPacketFraming.FramingError.outOfOrderChunk(let exp, let rec) = error else {
                XCTFail("Expected outOfOrderChunk for duplicate, got \(error)")
                return
            }
            XCTAssertEqual(exp, 2)
            XCTAssertEqual(rec, 1)
        }
    }

    func testBLEPacketFramingTruncatedHeaderRejection() {
        let reassembler = BLEPacketFraming.Reassembler()
        // Start chunk requires at least 5 bytes (1 flag + 4 length)
        let truncated = Data([0x80, 0x00, 0x01]) // only 3 bytes
        XCTAssertThrowsError(try reassembler.processChunk(truncated)) { error in
            guard case BLEPacketFraming.FramingError.truncatedHeader = error else {
                XCTFail("Expected truncatedHeader, got \(error)")
                return
            }
        }
    }

    func testBLEPacketFramingDeclaredLengthTampering() throws {
        let payload = Data("Valid payload".utf8)
        var chunks = try BLEPacketFraming.chunk(frame: payload, maxChunkSize: 180)

        // Corrupt declared length in the start header to claim 100 bytes instead of 13
        chunks[0][1] = 0x00
        chunks[0][2] = 0x00
        chunks[0][3] = 0x00
        chunks[0][4] = 0x64 // 100

        let reassembler = BLEPacketFraming.Reassembler()
        XCTAssertThrowsError(try reassembler.processChunk(chunks[0])) { error in
            guard case BLEPacketFraming.FramingError.lengthMismatch(let exp, let act) = error else {
                XCTFail("Expected lengthMismatch, got \(error)")
                return
            }
            XCTAssertEqual(exp, 100)
            XCTAssertEqual(act, 13)
        }
    }

    // MARK: - Mock Transport & Cryptographic Exchange Tests

    final class MockInvertedTransport: HandshakeFramedTransport, @unchecked Sendable {
        let transportType: TransportType = .bluetoothLE
        private var sendQueue: [Data] = []
        private var receiveQueue: [Data] = []
        private let lock = NSLock()
        private var _isOpen = true

        private func appendSend(_ data: Data) throws {
            lock.lock()
            defer { lock.unlock() }
            guard _isOpen else { throw BLETransportError.disconnected }
            sendQueue.append(data)
        }

        private func popReceive() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return receiveQueue.isEmpty ? nil : receiveQueue.removeFirst()
        }

        private func setClosed() {
            lock.lock()
            defer { lock.unlock() }
            _isOpen = false
        }

        func send(frameData: Data) async throws {
            try appendSend(frameData)
        }

        func receive(timeoutSeconds: TimeInterval?) async throws -> Data {
            let limit = timeoutSeconds ?? 5.0
            let start = Date()
            while Date().timeIntervalSince(start) < limit {
                if let item = popReceive() {
                    return item
                }
                try await Task.sleep(nanoseconds: 5_000_000) // 5ms
            }
            throw BLETransportError.timeout
        }

        func injectIncoming(frameData: Data) {
            lock.lock()
            defer { lock.unlock() }
            receiveQueue.append(frameData)
        }

        func popOutgoing() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return sendQueue.isEmpty ? nil : sendQueue.removeFirst()
        }

        func close() async {
            setClosed()
        }
    }

    func testFramedTransportCryptographicSessionRoundtrip() async throws {
        let testKeychain = KeychainManager(service: "com.handshake.test.bletransport")
        defer {
            try? testKeychain.delete(account: "test.ble.client.privateKey")
            try? testKeychain.delete(account: "test.ble.client.metadata")
            try? testKeychain.delete(account: "test.ble.host.privateKey")
            try? testKeychain.delete(account: "test.ble.host.metadata")
        }

        let sender = try CryptoIdentity.createNew(
            label: "test.ble.client",
            displayName: "iPhone 16e",
            deviceType: .iPhone,
            modelIdentifier: "iPhone17,5",
            systemVersion: "18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let recipient = try CryptoIdentity.createNew(
            label: "test.ble.host",
            displayName: "MacBook Air M4",
            deviceType: .mac,
            modelIdentifier: "Mac16,13",
            systemVersion: "15.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )

        // 1. Generate ephemeral key exchanges for client and host
        let clientEphemeral = EphemeralKeyExchange()
        let hostEphemeral = EphemeralKeyExchange()

        // 2. Perform mutual ECDH agreement
        let clientSecret = try clientEphemeral.computeSharedSecret(peerEphemeralPublicKeyHex: hostEphemeral.publicKeyHex)
        let hostSecret = try hostEphemeral.computeSharedSecret(peerEphemeralPublicKeyHex: clientEphemeral.publicKeyHex)

        // 3. Derive directional session keys with pre-shared key (PSK)
        let sessionId = UUID()
        let transcript = Data("test-transcript-ble-exchange".utf8)
        let psk = SymmetricKey(size: .bits256)

        let clientKeys = SessionKeyDerivation.deriveKeys(
            sharedSecret: clientSecret,
            sessionId: sessionId,
            transcript: transcript,
            masterPSK: psk
        )

        let hostKeys = SessionKeyDerivation.deriveKeys(
            sharedSecret: hostSecret,
            sessionId: sessionId,
            transcript: transcript,
            masterPSK: psk
        )

        // Verify directional symmetry
        XCTAssertEqual(
            clientKeys.clientToHostKey.withUnsafeBytes { Data($0) },
            hostKeys.clientToHostKey.withUnsafeBytes { Data($0) }
        )
        XCTAssertEqual(
            clientKeys.hostToClientKey.withUnsafeBytes { Data($0) },
            hostKeys.hostToClientKey.withUnsafeBytes { Data($0) }
        )

        // 4. Test encrypted command transmission over MockInvertedTransport
        let transport = MockInvertedTransport()
        let command = CommandMessage(command: .sleep)

        let sealedEnvelope = try SecureChannel.seal(
            message: command,
            sequenceNumber: 1,
            senderIdentity: sender,
            recipientPublicKeyHex: recipient.identity.publicKeyHex,
            sessionKey: clientKeys.clientToHostKey,
            nonceSalt: clientKeys.clientNonceSalt
        )

        let encodedEnvelope = try JSONEncoder().encode(sealedEnvelope)

        // Transmit frame over transport
        try await transport.send(frameData: encodedEnvelope)
        let sentFrame = transport.popOutgoing()
        XCTAssertNotNil(sentFrame)

        // Host receives and decrypts
        let decodedEnvelope = try JSONDecoder().decode(CommandEnvelope.self, from: sentFrame!)
        let receiverCounter = SequenceCounter()
        let decryptedCommand = try await SecureChannel.open(
            envelope: decodedEnvelope,
            sessionKey: hostKeys.clientToHostKey,
            trustedSenderPublicKeyHex: sender.identity.publicKeyHex,
            sequenceCounter: receiverCounter,
            expectedNonceSalt: hostKeys.clientNonceSalt
        )

        XCTAssertEqual(decryptedCommand.id, command.id)
        XCTAssertEqual(decryptedCommand.command, .sleep)

        // Host sends acknowledgment back through transport
        let hostDevice = recipient.identity

        let ack = CommandAcknowledgment(
            commandId: command.id,
            status: .executed,
            hostIdentity: hostDevice,
            signatureHex: "abcdef123456"
        )

        let encodedAck = try JSONEncoder().encode(ack)
        transport.injectIncoming(frameData: encodedAck)

        let receivedAckFrame = try await transport.receive(timeoutSeconds: 2.0)
        let decodedAck = try JSONDecoder().decode(CommandAcknowledgment.self, from: receivedAckFrame)

        XCTAssertEqual(decodedAck.commandId, command.id)
        XCTAssertEqual(decodedAck.status, .executed)

        await transport.close()
    }
}
