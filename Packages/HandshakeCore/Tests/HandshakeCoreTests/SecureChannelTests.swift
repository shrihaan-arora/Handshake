import XCTest
import CryptoKit
@testable import HandshakeCore

final class SecureChannelTests: XCTestCase {

    private let testKeychain = KeychainManager(service: "com.handshake.test.securechannel")

    override func tearDown() {
        super.tearDown()
        try? testKeychain.delete(account: "test.sender.id.privateKey")
        try? testKeychain.delete(account: "test.sender.id.metadata")
        try? testKeychain.delete(account: "test.recipient.id.privateKey")
        try? testKeychain.delete(account: "test.recipient.id.metadata")
    }

    // MARK: - 1. Happy Path Sealing & Opening

    func testSecureChannelSealAndOpenHappyPath() async throws {
        let sender = try CryptoIdentity.createNew(
            label: "test.sender.id",
            displayName: "iPhone 16e",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let recipient = try CryptoIdentity.createNew(
            label: "test.recipient.id",
            displayName: "MacBook Air M4",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "15.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )

        let sessionKey = SymmetricKey(size: .bits256)
        let receiverCounter = SequenceCounter()

        let originalCommand = CommandMessage(
            command: .lockScreen,
            timestamp: Date(),
            validityWindowSeconds: 30.0,
            parameters: ["urgency": "immediate"]
        )

        // Seal on iPhone
        let envelope = try SecureChannel.seal(
            message: originalCommand,
            sequenceNumber: 1,
            senderIdentity: sender,
            recipientPublicKeyHex: recipient.identity.publicKeyHex,
            sessionKey: sessionKey
        )

        XCTAssertEqual(envelope.sequenceNumber, 1)
        XCTAssertEqual(envelope.senderPublicKeyHex, sender.identity.publicKeyHex)
        XCTAssertFalse(envelope.ciphertextHex.isEmpty)
        XCTAssertFalse(envelope.authTagHex.isEmpty)
        XCTAssertFalse(envelope.signatureHex.isEmpty)

        // Open on Mac
        let decryptedCommand = try await SecureChannel.open(
            envelope: envelope,
            sessionKey: sessionKey,
            trustedSenderPublicKeyHex: sender.identity.publicKeyHex,
            sequenceCounter: receiverCounter
        )

        XCTAssertEqual(decryptedCommand.id, originalCommand.id)
        XCTAssertEqual(decryptedCommand.command, .lockScreen)
        XCTAssertEqual(decryptedCommand.parameters["urgency"], "immediate")
    }

    // MARK: - 2. Anti-Replay Protection

    func testSecureChannelReplayRejection() async throws {
        let sender = try CryptoIdentity.createNew(
            label: "test.sender.id",
            displayName: "iPhone",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let sessionKey = SymmetricKey(size: .bits256)
        let receiverCounter = SequenceCounter()

        let command = CommandMessage(command: .sleep)
        let envelope = try SecureChannel.seal(
            message: command,
            sequenceNumber: 42,
            senderIdentity: sender,
            recipientPublicKeyHex: "recipient_pk",
            sessionKey: sessionKey
        )

        // First delivery: accepted
        let first = try await SecureChannel.open(
            envelope: envelope,
            sessionKey: sessionKey,
            trustedSenderPublicKeyHex: sender.identity.publicKeyHex,
            sequenceCounter: receiverCounter
        )
        XCTAssertEqual(first.id, command.id)

        // Replay attempt: rejected
        do {
            _ = try await SecureChannel.open(
                envelope: envelope,
                sessionKey: sessionKey,
                trustedSenderPublicKeyHex: sender.identity.publicKeyHex,
                sequenceCounter: receiverCounter
            )
            XCTFail("Replayed envelope must be rejected")
        } catch {
            XCTAssertEqual(error as? SecureChannel.ChannelError, .replayDetected(42))
        }
    }

    // MARK: - 3. Tampering Rejection

    func testSecureChannelTamperingRejection() async throws {
        let sender = try CryptoIdentity.createNew(
            label: "test.sender.id",
            displayName: "iPhone",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let sessionKey = SymmetricKey(size: .bits256)
        let receiverCounter = SequenceCounter()

        let command = CommandMessage(command: .lockScreen)
        let envelope = try SecureChannel.seal(
            message: command,
            sequenceNumber: 1,
            senderIdentity: sender,
            recipientPublicKeyHex: "recipient_pk",
            sessionKey: sessionKey
        )

        // 1. Tamper with ciphertext
        var tamperedCiphertext = Data(hexString: envelope.ciphertextHex)!
        tamperedCiphertext[0] ^= 0xFF
        let tamperedEnvelope = CommandEnvelope(
            version: envelope.version,
            id: envelope.id,
            senderPublicKeyHex: envelope.senderPublicKeyHex,
            recipientPublicKeyHex: envelope.recipientPublicKeyHex,
            sequenceNumber: envelope.sequenceNumber,
            timestampMilliseconds: envelope.timestampMilliseconds,
            nonceHex: envelope.nonceHex,
            ciphertextHex: tamperedCiphertext.hexString,
            authTagHex: envelope.authTagHex,
            signatureHex: envelope.signatureHex
        )

        do {
            _ = try await SecureChannel.open(
                envelope: tamperedEnvelope,
                sessionKey: sessionKey,
                trustedSenderPublicKeyHex: sender.identity.publicKeyHex,
                sequenceCounter: receiverCounter
            )
            XCTFail("Tampered ciphertext must fail verification")
        } catch {
            XCTAssertEqual(error as? SecureChannel.ChannelError, .signatureVerificationFailed)
        }

        // 2. Tamper with digital signature
        var tamperedSig = Data(hexString: envelope.signatureHex)!
        tamperedSig[0] ^= 0xFF
        let badSigEnvelope = CommandEnvelope(
            version: envelope.version,
            id: envelope.id,
            senderPublicKeyHex: envelope.senderPublicKeyHex,
            recipientPublicKeyHex: envelope.recipientPublicKeyHex,
            sequenceNumber: envelope.sequenceNumber,
            timestampMilliseconds: envelope.timestampMilliseconds,
            nonceHex: envelope.nonceHex,
            ciphertextHex: envelope.ciphertextHex,
            authTagHex: envelope.authTagHex,
            signatureHex: tamperedSig.hexString
        )

        do {
            _ = try await SecureChannel.open(
                envelope: badSigEnvelope,
                sessionKey: sessionKey,
                trustedSenderPublicKeyHex: sender.identity.publicKeyHex,
                sequenceCounter: receiverCounter
            )
            XCTFail("Tampered signature must fail verification")
        } catch {
            XCTAssertEqual(error as? SecureChannel.ChannelError, .signatureVerificationFailed)
        }
    }

    // MARK: - 4. Untrusted Peer Rejection

    func testSecureChannelUntrustedPeerRejection() async throws {
        let sender = try CryptoIdentity.createNew(
            label: "test.sender.id",
            displayName: "iPhone",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let attacker = try CryptoIdentity.createNew(
            label: "test.attacker.id",
            displayName: "Attacker",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )

        let sessionKey = SymmetricKey(size: .bits256)
        let receiverCounter = SequenceCounter()

        // Attacker seals command
        let command = CommandMessage(command: .lockScreen)
        let envelope = try SecureChannel.seal(
            message: command,
            sequenceNumber: 1,
            senderIdentity: attacker,
            recipientPublicKeyHex: "mac_pk",
            sessionKey: sessionKey
        )

        // Mac expects legitimate paired sender, not attacker
        do {
            _ = try await SecureChannel.open(
                envelope: envelope,
                sessionKey: sessionKey,
                trustedSenderPublicKeyHex: sender.identity.publicKeyHex,
                sequenceCounter: receiverCounter
            )
            XCTFail("Untrusted sender must fail verification")
        } catch {
            XCTAssertEqual(error as? SecureChannel.ChannelError, .signatureVerificationFailed)
        }
    }

    // MARK: - 5. Clock Skew Rejection

    func testSecureChannelClockSkewRejection() async throws {
        let sender = try CryptoIdentity.createNew(
            label: "test.sender.id",
            displayName: "iPhone",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let sessionKey = SymmetricKey(size: .bits256)
        let receiverCounter = SequenceCounter()

        // Timestamp 10 minutes in the past
        let pastTime = Date().addingTimeInterval(-600)
        let command = CommandMessage(command: .lockScreen, timestamp: pastTime)

        let envelope = try SecureChannel.seal(
            message: command,
            sequenceNumber: 1,
            senderIdentity: sender,
            recipientPublicKeyHex: "mac_pk",
            sessionKey: sessionKey,
            referenceTime: pastTime
        )

        // Mac evaluates at current time
        do {
            _ = try await SecureChannel.open(
                envelope: envelope,
                sessionKey: sessionKey,
                trustedSenderPublicKeyHex: sender.identity.publicKeyHex,
                sequenceCounter: receiverCounter,
                referenceTime: Date()
            )
            XCTFail("Excessive clock skew must fail verification")
        } catch {
            guard case SecureChannel.ChannelError.clockSkewExceeded = error else {
                XCTFail("Expected clockSkewExceeded error, got \(error)")
                return
            }
        }
    }

    // MARK: - 6. Network Framing Bounded Buffer Tests

    func testNetworkFramingBoundaries() throws {
        let sampleData = "Handshake-Framing-Test-Payload".data(using: .utf8)!
        let framed = try NetworkFraming.frame(data: sampleData)

        // 4 bytes header + payload length
        XCTAssertEqual(framed.count, 4 + sampleData.count)

        // Header must be big-endian length
        let len = framed.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        XCTAssertEqual(len, UInt32(sampleData.count))

        // Oversized data (> 64 KB) must throw error
        let oversizedData = Data(count: Int(NetworkFraming.maximumFrameSizeBytes) + 1)
        XCTAssertThrowsError(try NetworkFraming.frame(data: oversizedData)) { error in
            guard case NetworkFraming.FramingError.frameTooLarge = error else {
                XCTFail("Expected frameTooLarge error")
                return
            }
        }
    }
}
