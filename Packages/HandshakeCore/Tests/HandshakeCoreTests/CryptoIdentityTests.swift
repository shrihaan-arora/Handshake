import XCTest
import CryptoKit
@testable import HandshakeCore

final class CryptoIdentityTests: XCTestCase {

    private let testKeychain = KeychainManager(service: "com.handshake.test.crypto")

    override func tearDown() {
        super.tearDown()
        try? testKeychain.delete(account: "test.key")
        try? testKeychain.delete(account: "test.identity.privateKey")
        try? testKeychain.delete(account: "test.identity.metadata")
    }

    // MARK: - 1. Keychain Storage Engine Tests

    func testKeychainBasicOperations() throws {
        let account = "test.key"
        let testPayload = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])

        // Save
        try testKeychain.save(data: testPayload, forAccount: account)
        XCTAssertTrue(testKeychain.contains(account: account))

        // Retrieve
        let retrieved = try testKeychain.retrieve(forAccount: account)
        XCTAssertEqual(retrieved, testPayload)

        // Overwrite
        let updatedPayload = Data([0xCA, 0xFE, 0xBA, 0xBE])
        try testKeychain.save(data: updatedPayload, forAccount: account)
        let retrievedUpdated = try testKeychain.retrieve(forAccount: account)
        XCTAssertEqual(retrievedUpdated, updatedPayload)

        // Delete
        try testKeychain.delete(account: account)
        XCTAssertFalse(testKeychain.contains(account: account))
        XCTAssertThrowsError(try testKeychain.retrieve(forAccount: account)) { error in
            XCTAssertEqual(error as? KeychainManager.KeychainError, .itemNotFound)
        }
    }

    // MARK: - 2. P-256 Identity Generation & Signing Tests

    func testIdentityGenerationAndSignatureVerification() throws {
        let identity = try CryptoIdentity.createNew(
            label: "test.identity",
            displayName: "Test Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 14.5",
            preferSecureEnclave: false, // Explicit software test for determinism in headless test runs
            keychain: testKeychain
        )

        XCTAssertFalse(identity.identity.publicKeyHex.isEmpty)
        XCTAssertEqual(identity.identity.displayName, "Test Mac")
        XCTAssertEqual(identity.identity.deviceType, .mac)

        // Sign test payload
        let testMessage = "LockScreenCommand-Sequence-1".data(using: .utf8)!
        let signature = try identity.sign(data: testMessage)

        // Signature must be raw 64-byte P-256 ECDSA (r || s)
        XCTAssertEqual(signature.count, 64)

        // Verification with authentic public key must succeed
        let isValid = CryptoIdentity.verify(
            signatureRaw: signature,
            for: testMessage,
            publicKeyHex: identity.identity.publicKeyHex
        )
        XCTAssertTrue(isValid, "Authentic signature must verify cleanly")

        // Verification with tampered payload must fail
        let tamperedMessage = "LockScreenCommand-Sequence-2".data(using: .utf8)!
        let isTamperedValid = CryptoIdentity.verify(
            signatureRaw: signature,
            for: tamperedMessage,
            publicKeyHex: identity.identity.publicKeyHex
        )
        XCTAssertFalse(isTamperedValid, "Tampered payload must fail signature verification")

        // Verification with corrupted signature must fail
        var corruptedSignature = signature
        corruptedSignature[0] ^= 0xFF
        let isCorruptedValid = CryptoIdentity.verify(
            signatureRaw: corruptedSignature,
            for: testMessage,
            publicKeyHex: identity.identity.publicKeyHex
        )
        XCTAssertFalse(isCorruptedValid, "Corrupted signature must fail verification")

        // Verification with a different public key must fail
        let differentIdentity = try CryptoIdentity.createNew(
            label: "test.different",
            displayName: "Attacker iPhone",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "iOS 18.0",
            preferSecureEnclave: false,
            keychain: testKeychain
        )
        let isWrongKeyValid = CryptoIdentity.verify(
            signatureRaw: signature,
            for: testMessage,
            publicKeyHex: differentIdentity.identity.publicKeyHex
        )
        XCTAssertFalse(isWrongKeyValid, "Wrong public key must fail signature verification")
    }

    // MARK: - 3. Fingerprint Derivation Determinism

    func testFingerprintDerivation() {
        // Valid 65-byte uncompressed point hex (130 characters)
        let sampleHex = "04" + String(repeating: "1a2b3c4d", count: 16)
        XCTAssertEqual(sampleHex.count, 130)

        let fp1 = CryptoIdentity.computeFingerprint(for: sampleHex)
        let fp2 = CryptoIdentity.computeFingerprint(for: sampleHex)

        XCTAssertEqual(fp1, fp2)
        XCTAssertTrue(fp1.contains("..."))
        XCTAssertEqual(fp1.count, 11) // 4 chars prefix + 3 chars "..." + 4 chars suffix
    }

    // MARK: - 4. Ephemeral P-256 ECDH Key Agreement & Directional Keys

    func testEphemeralECDHAndSessionKeyDerivation() throws {
        // Alice (iPhone) and Bob (Mac) generate ephemeral keys
        let alice = EphemeralKeyExchange()
        let bob = EphemeralKeyExchange()

        // Mutual key agreement
        let aliceSharedSecret = try alice.computeSharedSecret(peerEphemeralPublicKeyHex: bob.publicKeyHex)
        let bobSharedSecret = try bob.computeSharedSecret(peerEphemeralPublicKeyHex: alice.publicKeyHex)

        // Derive directional session keys
        let sessionId = UUID()
        let salt = "Handshake-Session-Salt-v1".data(using: .utf8)!

        let aliceKeys = try EphemeralKeyExchange.deriveSessionKeys(
            sharedSecret: aliceSharedSecret,
            salt: salt,
            sessionId: sessionId
        )
        let bobKeys = try EphemeralKeyExchange.deriveSessionKeys(
            sharedSecret: bobSharedSecret,
            salt: salt,
            sessionId: sessionId
        )

        // Directional keys must match across peers
        let aliceC2HBytes = aliceKeys.clientToHostKey.withUnsafeBytes { Data($0) }
        let bobC2HBytes = bobKeys.clientToHostKey.withUnsafeBytes { Data($0) }
        XCTAssertEqual(aliceC2HBytes, bobC2HBytes, "Client-to-Host session keys must match on both peers")

        let aliceH2CBytes = aliceKeys.hostToClientKey.withUnsafeBytes { Data($0) }
        let bobH2CBytes = bobKeys.hostToClientKey.withUnsafeBytes { Data($0) }
        XCTAssertEqual(aliceH2CBytes, bobH2CBytes, "Host-to-Client session keys must match on both peers")

        // Client-to-Host and Host-to-Client keys must NOT be identical (directional isolation)
        XCTAssertNotEqual(aliceC2HBytes, aliceH2CBytes, "Directional keys must be cryptographically isolated")
    }

    // MARK: - 5. Independent Short Authentication String (SAS) Derivation

    func testShortAuthenticationStringDerivation() throws {
        let alice = EphemeralKeyExchange()
        let bob = EphemeralKeyExchange()

        let aliceSecret = try alice.computeSharedSecret(peerEphemeralPublicKeyHex: bob.publicKeyHex)
        let bobSecret = try bob.computeSharedSecret(peerEphemeralPublicKeyHex: alice.publicKeyHex)

        let pairingNonce = "RandomPairingNonce12345".data(using: .utf8)!
        let transcript = "HostPK-ClientPK-InvitationUUID-Timestamp".data(using: .utf8)!

        // Both devices compute SAS independently
        let aliceSAS = EphemeralKeyExchange.deriveSAS(
            sharedSecret: aliceSecret,
            salt: pairingNonce,
            transcript: transcript
        )
        let bobSAS = EphemeralKeyExchange.deriveSAS(
            sharedSecret: bobSecret,
            salt: pairingNonce,
            transcript: transcript
        )

        // Both must match exactly
        XCTAssertEqual(aliceSAS.count, 6)
        XCTAssertEqual(aliceSAS, bobSAS, "Independently computed SAS codes must be identical on both peers")

        // Transcript tampering (e.g. Man-in-the-Middle altering a public key) causes SAS divergence
        let tamperedTranscript = "HostPK-AttackerPK-InvitationUUID-Timestamp".data(using: .utf8)!
        let mitmSAS = EphemeralKeyExchange.deriveSAS(
            sharedSecret: aliceSecret,
            salt: pairingNonce,
            transcript: tamperedTranscript
        )
        XCTAssertNotEqual(aliceSAS, mitmSAS, "Altered transcript must produce divergent SAS code")
    }

    // MARK: - 6. TrustStore Persistence & Revocation Tests

    func testTrustStoreLifecycle() async throws {
        let store = TrustStore(keychain: testKeychain, storageAccount: "test.truststore")
        try await store.removeAll()

        let peerDevice = DeviceIdentity(
            id: UUID(),
            publicKeyHex: "04aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899",
            displayName: "User's iPhone 16e",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "18.0"
        )

        let record = TrustRecord(
            peer: peerDevice,
            pairedAt: Date(),
            lastSeenAt: Date(),
            isRevoked: false,
            authorizedCapabilities: [.lockScreen, .sleep]
        )

        // Add to trust store
        try await store.addOrUpdate(record)

        // Query
        let retrieved = await store.getRecord(id: record.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.peer.displayName, "User's iPhone 16e")

        let isTrusted = await store.isDeviceTrusted(publicKeyHex: peerDevice.publicKeyHex)
        XCTAssertTrue(isTrusted, "Device must be trusted initially")

        // Revoke
        try await store.revoke(id: record.id)
        let isTrustedAfterRevoke = await store.isDeviceTrusted(publicKeyHex: peerDevice.publicKeyHex)
        XCTAssertFalse(isTrustedAfterRevoke, "Revoked device must not be trusted")

        let revokedRecord = await store.getRecord(id: record.id)
        XCTAssertTrue(revokedRecord?.isRevoked ?? false)
        XCTAssertNotNil(revokedRecord?.revokedAt)

        // Verify persistence across new TrustStore instance (simulating app restart)
        let reloadedStore = TrustStore(keychain: testKeychain, storageAccount: "test.truststore")
        let reloadedRecord = await reloadedStore.getRecord(id: record.id)
        XCTAssertNotNil(reloadedRecord, "Record must survive app restart via Keychain")
        XCTAssertTrue(reloadedRecord?.isRevoked ?? false)

        // Remove
        try await reloadedStore.remove(id: record.id)
        let removedRecord = await reloadedStore.getRecord(id: record.id)
        XCTAssertNil(removedRecord)
    }
}
