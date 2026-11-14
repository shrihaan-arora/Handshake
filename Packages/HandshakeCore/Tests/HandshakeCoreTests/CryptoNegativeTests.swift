import XCTest
import CryptoKit
import Network
@testable import HandshakeCore

final class CryptoNegativeTests: XCTestCase {

    private let testKeychain = KeychainManager(service: "com.handshake.test.cryptonegative")

    override func tearDown() {
        super.tearDown()
        try? testKeychain.delete(account: "test.neg.sender.privateKey")
        try? testKeychain.delete(account: "test.neg.sender.metadata")
        try? testKeychain.delete(account: "test.neg.recipient.privateKey")
        try? testKeychain.delete(account: "test.neg.recipient.metadata")
        try? testKeychain.delete(account: "test.neg.attacker.privateKey")
        try? testKeychain.delete(account: "test.neg.attacker.metadata")
    }

    // MARK: - 1. Adversarial Tampering: Bit-level Ciphertext Modification

    func testAlteredCiphertextBitFlipFailsDecryption() async throws {
        let sender = try CryptoIdentity.createNew(
            label: "test.neg.sender",
            displayName: "Test Sender",
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
            recipientPublicKeyHex: "test_recipient_pk",
            sessionKey: sessionKey
        )

        // Modify a single byte in ciphertext
        guard var ciphertextData = Data(hexString: envelope.ciphertextHex), !ciphertextData.isEmpty else {
            XCTFail("Ciphertext should not be empty")
            return
        }
        ciphertextData[ciphertextData.count / 2] ^= 0x01

        let tamperedEnvelope = CommandEnvelope(
            version: envelope.version,
            id: envelope.id,
            senderPublicKeyHex: envelope.senderPublicKeyHex,
            recipientPublicKeyHex: envelope.recipientPublicKeyHex,
            sequenceNumber: envelope.sequenceNumber,
            timestampMilliseconds: envelope.timestampMilliseconds,
            nonceHex: envelope.nonceHex,
            ciphertextHex: ciphertextData.hexString,
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
            XCTFail("Altered ciphertext must be rejected")
        } catch {
            // Digital signature covers (AAD || Ciphertext || AuthTag), so altering ciphertext fails signature or decryption
            XCTAssertTrue(
                error as? SecureChannel.ChannelError == .signatureVerificationFailed ||
                error as? SecureChannel.ChannelError == .decryptionFailed,
                "Expected signatureVerificationFailed or decryptionFailed, got \(error)"
            )
        }
    }

    // MARK: - 2. Adversarial Tampering: Substituted Public Key Identity

    func testSubstitutedPublicIdentityFailsSignatureVerification() async throws {
        let sender = try CryptoIdentity.createNew(
            label: "test.neg.sender",
            displayName: "Sender",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let attacker = try CryptoIdentity.createNew(
            label: "test.neg.attacker",
            displayName: "Attacker",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )

        let sessionKey = SymmetricKey(size: .bits256)
        let receiverCounter = SequenceCounter()

        let command = CommandMessage(command: .lockScreen)
        // Attacker creates envelope signed by attacker
        let attackerEnvelope = try SecureChannel.seal(
            message: command,
            sequenceNumber: 1,
            senderIdentity: attacker,
            recipientPublicKeyHex: "test_recipient_pk",
            sessionKey: sessionKey
        )

        // Substitute the senderPublicKeyHex with the legitimate sender's public key (spoofing sender)
        let spoofedEnvelope = CommandEnvelope(
            version: attackerEnvelope.version,
            id: attackerEnvelope.id,
            senderPublicKeyHex: sender.identity.publicKeyHex, // Spoofed!
            recipientPublicKeyHex: attackerEnvelope.recipientPublicKeyHex,
            sequenceNumber: attackerEnvelope.sequenceNumber,
            timestampMilliseconds: attackerEnvelope.timestampMilliseconds,
            nonceHex: attackerEnvelope.nonceHex,
            ciphertextHex: attackerEnvelope.ciphertextHex,
            authTagHex: attackerEnvelope.authTagHex,
            signatureHex: attackerEnvelope.signatureHex
        )

        do {
            _ = try await SecureChannel.open(
                envelope: spoofedEnvelope,
                sessionKey: sessionKey,
                trustedSenderPublicKeyHex: sender.identity.publicKeyHex,
                sequenceCounter: receiverCounter
            )
            XCTFail("Spoofed identity must fail digital signature verification")
        } catch {
            XCTAssertEqual(error as? SecureChannel.ChannelError, .signatureVerificationFailed)
        }
    }

    // MARK: - 3. Wrong Session Key Fails Decryption

    func testWrongSessionKeyFailsDecryption() async throws {
        let sender = try CryptoIdentity.createNew(
            label: "test.neg.sender",
            displayName: "Sender",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let sessionKeyA = SymmetricKey(size: .bits256)
        let sessionKeyB = SymmetricKey(size: .bits256)
        let receiverCounter = SequenceCounter()

        let command = CommandMessage(command: .lockScreen)
        let envelope = try SecureChannel.seal(
            message: command,
            sequenceNumber: 1,
            senderIdentity: sender,
            recipientPublicKeyHex: "test_recipient_pk",
            sessionKey: sessionKeyA
        )

        // Attempt decryption with wrong key B
        do {
            _ = try await SecureChannel.open(
                envelope: envelope,
                sessionKey: sessionKeyB,
                trustedSenderPublicKeyHex: sender.identity.publicKeyHex,
                sequenceCounter: receiverCounter
            )
            XCTFail("Decryption with incorrect session key must fail")
        } catch {
            XCTAssertEqual(error as? SecureChannel.ChannelError, .decryptionFailed)
        }
    }

    // MARK: - 4. Clock Skew Boundaries

    func testClockSkewExactBoundaries() async throws {
        let sender = try CryptoIdentity.createNew(
            label: "test.neg.sender",
            displayName: "Sender",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let sessionKey = SymmetricKey(size: .bits256)
        let referenceTime = Date()

        // 31 seconds in the past -> must fail
        let past31s = referenceTime.addingTimeInterval(-31.0)
        let envelopePast = try SecureChannel.seal(
            message: CommandMessage(command: .lockScreen),
            sequenceNumber: 1,
            senderIdentity: sender,
            recipientPublicKeyHex: "mac_pk",
            sessionKey: sessionKey,
            referenceTime: past31s
        )

        do {
            _ = try await SecureChannel.open(
                envelope: envelopePast,
                sessionKey: sessionKey,
                trustedSenderPublicKeyHex: sender.identity.publicKeyHex,
                sequenceCounter: SequenceCounter(),
                referenceTime: referenceTime
            )
            XCTFail("Timestamp skewed by 31 seconds must be rejected")
        } catch {
            guard case SecureChannel.ChannelError.clockSkewExceeded = error else {
                XCTFail("Expected clockSkewExceeded, got \(error)")
                return
            }
        }

        // 20 seconds in the future -> within 30s window -> passes
        let future20s = referenceTime.addingTimeInterval(20.0)
        let envelopeFuture = try SecureChannel.seal(
            message: CommandMessage(command: .lockScreen),
            sequenceNumber: 1,
            senderIdentity: sender,
            recipientPublicKeyHex: "mac_pk",
            sessionKey: sessionKey,
            referenceTime: future20s
        )

        let opened = try await SecureChannel.open(
            envelope: envelopeFuture,
            sessionKey: sessionKey,
            trustedSenderPublicKeyHex: sender.identity.publicKeyHex,
            sequenceCounter: SequenceCounter(),
            referenceTime: referenceTime
        )
        XCTAssertEqual(opened.command, .lockScreen)
    }

    // MARK: - 5. Revoked Device Rejection in Trust Store & Server

    func testRevokedDeviceCommandRejection() async throws {
        let hostId = try CryptoIdentity.createNew(
            label: "test.neg.recipient",
            displayName: "Host Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "15.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let revokedClient = try CryptoIdentity.createNew(
            label: "test.neg.sender",
            displayName: "Stolen iPhone",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "test.neg.truststore")
        var record = TrustRecord(peer: revokedClient.identity)
        record.revoke()
        try await trustStore.addOrUpdate(record)

        // Verify Trust Store records it as revoked
        let fetched = await trustStore.getRecord(publicKeyHex: revokedClient.identity.publicKeyHex)
        XCTAssertNotNil(fetched)
        XCTAssertTrue(fetched!.isRevoked)

        // Launch loopback server to verify server fails closed on revoked device
        let server = HandshakeServer(
            port: 5901,
            serviceType: "_revoked_test._tcp",
            hostIdentity: hostId,
            trustStore: trustStore,
            executionHandler: { _, _ in .executed }
        )
        try await server.start()
        defer {
            Task { await server.stop() }
        }

        let client = HandshakeClient(clientIdentity: revokedClient)
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 5901)

        do {
            _ = try await client.sendCommand(.lockScreen, to: endpoint, trustedHostPublicKeyHex: hostId.identity.publicKeyHex)
            XCTFail("Revoked device command must be rejected by server")
        } catch {
            guard case HandshakeClient.ClientError.commandRejected(let reason) = error else {
                XCTFail("Expected commandRejected error, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("revoked"), "Rejection reason must mention revocation, got '\(reason)'")
        }
    }

    // MARK: - 6. Two-Stage Sleep Handshake Verification

    func testTwoStageSleepHandshakeWithSignedReceipt() async throws {
        let hostId = try CryptoIdentity.createNew(
            label: "test.neg.recipient",
            displayName: "Host Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "15.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let clientId = try CryptoIdentity.createNew(
            label: "test.neg.sender",
            displayName: "Paired iPhone",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )

        let trustStore = TrustStore(keychain: testKeychain, storageAccount: "test.neg.truststore.sleep")
        let record = TrustRecord(peer: clientId.identity, authorizedCapabilities: [.sleep])
        try await trustStore.addOrUpdate(record)

        let serverPort: UInt16 = 5902
        let server = HandshakeServer(
            port: serverPort,
            serviceType: "_sleeptest._tcp",
            hostIdentity: hostId,
            trustStore: trustStore,
            executionHandler: { message, _ in
                XCTAssertEqual(message.command, .sleep)
                return .executed
            }
        )
        try await server.start()
        defer {
            Task { await server.stop() }
        }

        let client = HandshakeClient(clientIdentity: clientId)
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: serverPort))

        // Dispatch sleep command: client receives ack and automatically returns signed CommandReceipt
        let ack = try await client.sendCommand(.sleep, to: endpoint, trustedHostPublicKeyHex: hostId.identity.publicKeyHex)
        XCTAssertEqual(ack.status, .executed)
        XCTAssertEqual(ack.hostIdentity.publicKeyHex, hostId.identity.publicKeyHex)
    }
}
