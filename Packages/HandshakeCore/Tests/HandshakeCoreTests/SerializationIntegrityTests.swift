import XCTest
@testable import HandshakeCore

final class SerializationIntegrityTests: XCTestCase {

    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    // MARK: - 1. Comprehensive Encode/Decode Round Trips

    func testAllModelsSerializationRoundTrip() throws {
        let baseDate = Date(timeIntervalSince1970: 1700000000)

        // 1. DeviceIdentity
        let hostDevice = DeviceIdentity(
            publicKeyHex: "0123456789abcdef0123456789abcdef",
            displayName: "Test Host Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 14.5",
            createdAt: baseDate
        )
        let clientDevice = DeviceIdentity(
            publicKeyHex: "fedcba9876543210fedcba9876543210",
            displayName: "Test Client iPhone",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "iOS 18.0",
            createdAt: baseDate
        )
        XCTAssertEqual(try jsonDecoder.decode(DeviceIdentity.self, from: try jsonEncoder.encode(hostDevice)), hostDevice)
        XCTAssertEqual(try jsonDecoder.decode(DeviceIdentity.self, from: try jsonEncoder.encode(clientDevice)), clientDevice)

        // 2. ProtocolVersion
        let version = ProtocolVersion(major: 1, minor: 2)
        XCTAssertEqual(try jsonDecoder.decode(ProtocolVersion.self, from: try jsonEncoder.encode(version)), version)

        // 3. CommandMessage
        let command = CommandMessage(
            command: .lockScreen,
            timestamp: baseDate,
            validityWindowSeconds: 30.0,
            parameters: ["urgency": "immediate"]
        )
        XCTAssertEqual(try jsonDecoder.decode(CommandMessage.self, from: try jsonEncoder.encode(command)), command)

        // 4. CommandEnvelope
        let envelope = CommandEnvelope(
            version: 1,
            senderPublicKeyHex: hostDevice.publicKeyHex,
            recipientPublicKeyHex: clientDevice.publicKeyHex,
            sequenceNumber: 101,
            timestampMilliseconds: 1700000000000,
            nonceHex: "00112233445566778899aabb",
            ciphertextHex: "a1b2c3d4e5f6",
            authTagHex: "1234567890abcdef",
            signatureHex: "abcdef1234567890"
        )
        XCTAssertEqual(try jsonDecoder.decode(CommandEnvelope.self, from: try jsonEncoder.encode(envelope)), envelope)

        // 5. PairingInvitation
        let invitation = PairingInvitation(
            hostIdentity: hostDevice,
            ephemeralPublicKeyHex: "aabbccdd",
            createdAt: baseDate,
            lifetimeSeconds: 120
        )
        XCTAssertEqual(try jsonDecoder.decode(PairingInvitation.self, from: try jsonEncoder.encode(invitation)), invitation)

        // 6. PairingRequest
        let request = PairingRequest(
            invitationId: invitation.id,
            clientIdentity: clientDevice,
            clientEphemeralPublicKeyHex: "eeff0011",
            nonceProofHex: "22334455"
        )
        XCTAssertEqual(try jsonDecoder.decode(PairingRequest.self, from: try jsonEncoder.encode(request)), request)

        // 7. PairingResponse
        let response = PairingResponse(
            invitationId: invitation.id,
            hostIdentity: hostDevice,
            hostEphemeralPublicKeyHex: "aabbccdd",
            sasFingerprintCode: "948201"
        )
        XCTAssertEqual(try jsonDecoder.decode(PairingResponse.self, from: try jsonEncoder.encode(response)), response)

        // 8. PairingConfirmation
        let confirmation = PairingConfirmation(
            invitationId: invitation.id,
            isApproved: true,
            confirmedSASCode: "948201"
        )
        XCTAssertEqual(try jsonDecoder.decode(PairingConfirmation.self, from: try jsonEncoder.encode(confirmation)), confirmation)

        // 9. TrustRecord
        let trustRecord = TrustRecord(
            peer: clientDevice,
            pairedAt: baseDate,
            lastSeenAt: baseDate,
            isRevoked: false,
            revokedAt: nil,
            authorizedCapabilities: [.lockScreen, .sleep]
        )
        XCTAssertEqual(try jsonDecoder.decode(TrustRecord.self, from: try jsonEncoder.encode(trustRecord)), trustRecord)

        // 10. PairingCompletion
        let completion = PairingCompletion(
            invitationId: invitation.id,
            isSuccessful: true,
            establishedTrustRecord: trustRecord
        )
        XCTAssertEqual(try jsonDecoder.decode(PairingCompletion.self, from: try jsonEncoder.encode(completion)), completion)
    }

    // MARK: - 2. Associated-Data Consistency and Sensitivity

    func testAssociatedDataSensitivityToFieldAlteration() {
        let envelope = CommandEnvelope(
            version: 1,
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            senderPublicKeyHex: "AAAA",
            recipientPublicKeyHex: "BBBB",
            sequenceNumber: 1,
            timestampMilliseconds: 1700000000000,
            nonceHex: "0011",
            ciphertextHex: "dead",
            authTagHex: "beef",
            signatureHex: "feed"
        )

        let baselineAAD = envelope.associatedDataPayload
        XCTAssertFalse(baselineAAD.isEmpty)

        // 1. Modifying version changes AAD
        let envelopeVersion = CommandEnvelope(
            version: 2,
            id: envelope.id,
            senderPublicKeyHex: envelope.senderPublicKeyHex,
            recipientPublicKeyHex: envelope.recipientPublicKeyHex,
            sequenceNumber: envelope.sequenceNumber,
            timestampMilliseconds: envelope.timestampMilliseconds,
            nonceHex: envelope.nonceHex,
            ciphertextHex: envelope.ciphertextHex,
            authTagHex: envelope.authTagHex,
            signatureHex: envelope.signatureHex
        )
        XCTAssertNotEqual(envelopeVersion.associatedDataPayload, baselineAAD)

        // 2. Modifying ID changes AAD
        let envelopeID = CommandEnvelope(
            version: envelope.version,
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            senderPublicKeyHex: envelope.senderPublicKeyHex,
            recipientPublicKeyHex: envelope.recipientPublicKeyHex,
            sequenceNumber: envelope.sequenceNumber,
            timestampMilliseconds: envelope.timestampMilliseconds,
            nonceHex: envelope.nonceHex,
            ciphertextHex: envelope.ciphertextHex,
            authTagHex: envelope.authTagHex,
            signatureHex: envelope.signatureHex
        )
        XCTAssertNotEqual(envelopeID.associatedDataPayload, baselineAAD)

        // 3. Modifying sequence number changes AAD
        let envelopeSeq = CommandEnvelope(
            version: envelope.version,
            id: envelope.id,
            senderPublicKeyHex: envelope.senderPublicKeyHex,
            recipientPublicKeyHex: envelope.recipientPublicKeyHex,
            sequenceNumber: 2,
            timestampMilliseconds: envelope.timestampMilliseconds,
            nonceHex: envelope.nonceHex,
            ciphertextHex: envelope.ciphertextHex,
            authTagHex: envelope.authTagHex,
            signatureHex: envelope.signatureHex
        )
        XCTAssertNotEqual(envelopeSeq.associatedDataPayload, baselineAAD)

        // 4. Modifying timestamp by 1 ms changes AAD
        let envelopeTime = CommandEnvelope(
            version: envelope.version,
            id: envelope.id,
            senderPublicKeyHex: envelope.senderPublicKeyHex,
            recipientPublicKeyHex: envelope.recipientPublicKeyHex,
            sequenceNumber: envelope.sequenceNumber,
            timestampMilliseconds: envelope.timestampMilliseconds + 1,
            nonceHex: envelope.nonceHex,
            ciphertextHex: envelope.ciphertextHex,
            authTagHex: envelope.authTagHex,
            signatureHex: envelope.signatureHex
        )
        XCTAssertNotEqual(envelopeTime.associatedDataPayload, baselineAAD)

        // 5. Modifying sender public key changes AAD
        let envelopeSender = CommandEnvelope(
            version: envelope.version,
            id: envelope.id,
            senderPublicKeyHex: "AAAB",
            recipientPublicKeyHex: envelope.recipientPublicKeyHex,
            sequenceNumber: envelope.sequenceNumber,
            timestampMilliseconds: envelope.timestampMilliseconds,
            nonceHex: envelope.nonceHex,
            ciphertextHex: envelope.ciphertextHex,
            authTagHex: envelope.authTagHex,
            signatureHex: envelope.signatureHex
        )
        XCTAssertNotEqual(envelopeSender.associatedDataPayload, baselineAAD)

        // 6. Modifying recipient public key changes AAD
        let envelopeRecipient = CommandEnvelope(
            version: envelope.version,
            id: envelope.id,
            senderPublicKeyHex: envelope.senderPublicKeyHex,
            recipientPublicKeyHex: "BBBC",
            sequenceNumber: envelope.sequenceNumber,
            timestampMilliseconds: envelope.timestampMilliseconds,
            nonceHex: envelope.nonceHex,
            ciphertextHex: envelope.ciphertextHex,
            authTagHex: envelope.authTagHex,
            signatureHex: envelope.signatureHex
        )
        XCTAssertNotEqual(envelopeRecipient.associatedDataPayload, baselineAAD)
    }

    // MARK: - 3. Field Alteration and Serialization Detection

    func testEnvelopeFieldAlterationDetection() throws {
        let envelope = CommandEnvelope(
            senderPublicKeyHex: "0123",
            recipientPublicKeyHex: "4567",
            sequenceNumber: 1,
            nonceHex: "00112233445566778899aabb",
            ciphertextHex: "original_ciphertext_hex",
            authTagHex: "original_tag",
            signatureHex: "original_sig"
        )
        let encodedData = try jsonEncoder.encode(envelope)
        guard var jsonDict = try JSONSerialization.jsonObject(with: encodedData) as? [String: Any] else {
            XCTFail("Failed to convert to dictionary")
            return
        }

        // Alter ciphertext
        jsonDict["ciphertextHex"] = "tampered_ciphertext_hex"
        let alteredCiphertextData = try JSONSerialization.data(withJSONObject: jsonDict)
        let decodedAlteredCiphertext = try jsonDecoder.decode(CommandEnvelope.self, from: alteredCiphertextData)
        XCTAssertNotEqual(decodedAlteredCiphertext.ciphertextHex, envelope.ciphertextHex)
        XCTAssertNotEqual(decodedAlteredCiphertext, envelope)

        // Alter nonce
        jsonDict["nonceHex"] = "tampered_nonce"
        let alteredNonceData = try JSONSerialization.data(withJSONObject: jsonDict)
        let decodedAlteredNonce = try jsonDecoder.decode(CommandEnvelope.self, from: alteredNonceData)
        XCTAssertNotEqual(decodedAlteredNonce.nonceHex, envelope.nonceHex)

        // Alter auth tag
        jsonDict["authTagHex"] = "tampered_tag"
        let alteredTagData = try JSONSerialization.data(withJSONObject: jsonDict)
        let decodedAlteredTag = try jsonDecoder.decode(CommandEnvelope.self, from: alteredTagData)
        XCTAssertNotEqual(decodedAlteredTag.authTagHex, envelope.authTagHex)

        // Alter signature
        jsonDict["signatureHex"] = "tampered_signature"
        let alteredSigData = try JSONSerialization.data(withJSONObject: jsonDict)
        let decodedAlteredSig = try jsonDecoder.decode(CommandEnvelope.self, from: alteredSigData)
        XCTAssertNotEqual(decodedAlteredSig.signatureHex, envelope.signatureHex)
    }

    // MARK: - 4. Protocol Version Compatibility Mismatch

    func testProtocolVersionCompatibilityConstraints() {
        let current = ProtocolVersion.current
        XCTAssertEqual(current.major, 1)
        XCTAssertEqual(current.minor, 0)
        XCTAssertTrue(current.isCompatible)

        // Minor version increments within the same major version are compatible
        let compatibleMinor = ProtocolVersion(major: 1, minor: 1)
        XCTAssertTrue(compatibleMinor.isCompatible)

        let compatibleHigherMinor = ProtocolVersion(major: 1, minor: 99)
        XCTAssertTrue(compatibleHigherMinor.isCompatible)

        // Major version increments are NOT compatible (breaking changes)
        let breakingMajor = ProtocolVersion(major: 2, minor: 0)
        XCTAssertFalse(breakingMajor.isCompatible)

        let breakingMajorHigher = ProtocolVersion(major: 3, minor: 0)
        XCTAssertFalse(breakingMajorHigher.isCompatible)

        // Older major versions are NOT compatible
        let olderMajor = ProtocolVersion(major: 0, minor: 9)
        XCTAssertFalse(olderMajor.isCompatible)
    }

    // MARK: - 5. Timestamp Alteration and Validation

    func testTimestampAlterationRejection() throws {
        let referenceTime = Date()
        let envelope = CommandEnvelope(
            senderPublicKeyHex: "0123",
            recipientPublicKeyHex: "4567",
            sequenceNumber: 1,
            timestampMilliseconds: Int64(referenceTime.timeIntervalSince1970 * 1000),
            nonceHex: "0011",
            ciphertextHex: "aabb",
            authTagHex: "ccdd",
            signatureHex: "eeff"
        )

        // Baseline timestamp is valid
        XCTAssertTrue(HandshakeTime.isTimestampValid(envelope.timestampMilliseconds, referenceTime: referenceTime))

        // Altering timestamp to 1 hour in the past (clock skew violation)
        let alteredPastMs = envelope.timestampMilliseconds - (3600 * 1000)
        XCTAssertFalse(HandshakeTime.isTimestampValid(alteredPastMs, referenceTime: referenceTime))

        // Altering timestamp to 1 hour in the future (future skew violation)
        let alteredFutureMs = envelope.timestampMilliseconds + (3600 * 1000)
        XCTAssertFalse(HandshakeTime.isTimestampValid(alteredFutureMs, referenceTime: referenceTime))

        // Altering CommandMessage timestamp
        let validCommand = CommandMessage(
            command: .lockScreen,
            timestamp: referenceTime,
            validityWindowSeconds: 30.0
        )
        XCTAssertFalse(validCommand.isExpired(at: referenceTime))

        let expiredCommand = CommandMessage(
            command: .lockScreen,
            timestamp: referenceTime.addingTimeInterval(-60.0),
            validityWindowSeconds: 30.0
        )
        XCTAssertTrue(expiredCommand.isExpired(at: referenceTime))
    }

    // MARK: - 6. Command Identifier Alteration and Binding

    func testCommandIdentifierAlteration() throws {
        let originalID = UUID()
        let command = CommandMessage(id: originalID, command: .sleep)

        let data = try jsonEncoder.encode(command)
        guard var jsonDict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to convert to dictionary")
            return
        }

        // Alter UUID string in JSON representation
        let alteredID = UUID()
        jsonDict["id"] = alteredID.uuidString
        let alteredData = try JSONSerialization.data(withJSONObject: jsonDict)

        let decoded = try jsonDecoder.decode(CommandMessage.self, from: alteredData)
        XCTAssertEqual(decoded.id, alteredID)
        XCTAssertNotEqual(decoded.id, originalID)

        // An envelope carrying this message must bind the matching ID; divergence indicates tampering
        let envelope = CommandEnvelope(
            id: originalID,
            senderPublicKeyHex: "0123",
            recipientPublicKeyHex: "4567",
            sequenceNumber: 1,
            nonceHex: "00",
            ciphertextHex: "00",
            authTagHex: "00",
            signatureHex: "00"
        )
        XCTAssertNotEqual(envelope.id, decoded.id, "Mismatched envelope ID and command ID must not match")
    }
}
