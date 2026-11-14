import XCTest
@testable import HandshakeCore

final class MalformedInputTests: XCTestCase {

    private let jsonDecoder = JSONDecoder()

    // MARK: - 1. Empty and Truncated Payloads

    func testAllModelsRejectEmptyData() {
        let emptyData = Data()

        XCTAssertThrowsError(try jsonDecoder.decode(CommandEnvelope.self, from: emptyData))
        XCTAssertThrowsError(try jsonDecoder.decode(CommandMessage.self, from: emptyData))
        XCTAssertThrowsError(try jsonDecoder.decode(PairingInvitation.self, from: emptyData))
        XCTAssertThrowsError(try jsonDecoder.decode(PairingRequest.self, from: emptyData))
        XCTAssertThrowsError(try jsonDecoder.decode(PairingResponse.self, from: emptyData))
        XCTAssertThrowsError(try jsonDecoder.decode(PairingConfirmation.self, from: emptyData))
        XCTAssertThrowsError(try jsonDecoder.decode(PairingCompletion.self, from: emptyData))
        XCTAssertThrowsError(try jsonDecoder.decode(TrustRecord.self, from: emptyData))
        XCTAssertThrowsError(try jsonDecoder.decode(DeviceIdentity.self, from: emptyData))
        XCTAssertThrowsError(try jsonDecoder.decode(ProtocolVersion.self, from: emptyData))
    }

    func testAllModelsRejectTruncatedJSON() throws {
        let envelope = CommandEnvelope(
            senderPublicKeyHex: "0123456789abcdef",
            recipientPublicKeyHex: "fedcba9876543210",
            sequenceNumber: 1,
            nonceHex: "00112233445566778899aabb",
            ciphertextHex: "deadbeef",
            authTagHex: "cafebabe11223344",
            signatureHex: "abcd"
        )
        let fullData = try JSONEncoder().encode(envelope)

        // Test progressive truncation at multiple byte offsets
        let truncationPoints = [1, 5, 10, fullData.count / 4, fullData.count / 2, fullData.count - 1]
        for point in truncationPoints where point < fullData.count {
            let truncated = fullData.prefix(point)
            XCTAssertThrowsError(try jsonDecoder.decode(CommandEnvelope.self, from: truncated),
                                 "Failed to reject truncated data at byte length \(point)")
        }
    }

    // MARK: - 2. Invalid and Corrupted JSON Syntax

    func testAllModelsRejectCorruptedSyntax() {
        let malformedStrings = [
            "{",
            "}",
            "{ \"version\": ",
            "{\"version\": 1, }",
            "[1, 2, 3]",
            "null",
            "true",
            "\"just a string\"",
            "123456",
            "<html><body>Not JSON</body></html>",
            "\u{00}\u{01}\u{02}\u{FF}\u{FE}"
        ]

        for malformed in malformedStrings {
            let data = Data(malformed.utf8)
            XCTAssertThrowsError(try jsonDecoder.decode(CommandEnvelope.self, from: data))
            XCTAssertThrowsError(try jsonDecoder.decode(CommandMessage.self, from: data))
            XCTAssertThrowsError(try jsonDecoder.decode(PairingInvitation.self, from: data))
            XCTAssertThrowsError(try jsonDecoder.decode(PairingRequest.self, from: data))
            XCTAssertThrowsError(try jsonDecoder.decode(PairingResponse.self, from: data))
            XCTAssertThrowsError(try jsonDecoder.decode(PairingConfirmation.self, from: data))
            XCTAssertThrowsError(try jsonDecoder.decode(PairingCompletion.self, from: data))
            XCTAssertThrowsError(try jsonDecoder.decode(TrustRecord.self, from: data))
            XCTAssertThrowsError(try jsonDecoder.decode(DeviceIdentity.self, from: data))
            XCTAssertThrowsError(try jsonDecoder.decode(ProtocolVersion.self, from: data))
        }
    }

    // MARK: - 3. Missing Required Fields

    func testCommandEnvelopeMissingFields() {
        let baseJson: [String: Any] = [
            "version": 1,
            "id": UUID().uuidString,
            "senderPublicKeyHex": "0123",
            "recipientPublicKeyHex": "4567",
            "sequenceNumber": 42,
            "timestampMilliseconds": 1700000000000,
            "nonceHex": "001122",
            "ciphertextHex": "aabb",
            "authTagHex": "ccdd",
            "signatureHex": "eeff"
        ]

        let requiredKeys = ["version", "id", "senderPublicKeyHex", "recipientPublicKeyHex",
                            "sequenceNumber", "timestampMilliseconds", "nonceHex",
                            "ciphertextHex", "authTagHex", "signatureHex"]

        for key in requiredKeys {
            var incomplete = baseJson
            incomplete.removeValue(forKey: key)
            let data = try! JSONSerialization.data(withJSONObject: incomplete)
            XCTAssertThrowsError(try jsonDecoder.decode(CommandEnvelope.self, from: data),
                                 "Should fail when missing key: \(key)")
        }
    }

    func testPairingRequestMissingFields() {
        let baseJson: [String: Any] = [
            "invitationId": UUID().uuidString,
            "clientIdentity": [
                "id": UUID().uuidString,
                "publicKeyHex": "aabb",
                "displayName": "iPhone",
                "deviceType": "iPhone",
                "modelIdentifier": "iPhone16,1",
                "systemVersion": "18.0",
                "createdAt": 1700000000.0
            ],
            "clientEphemeralPublicKeyHex": "ccdd",
            "nonceProofHex": "eeff"
        ]

        for key in ["invitationId", "clientIdentity", "clientEphemeralPublicKeyHex", "nonceProofHex"] {
            var incomplete = baseJson
            incomplete.removeValue(forKey: key)
            let data = try! JSONSerialization.data(withJSONObject: incomplete)
            XCTAssertThrowsError(try jsonDecoder.decode(PairingRequest.self, from: data),
                                 "Should fail when missing key: \(key)")
        }
    }

    // MARK: - 4. Unknown Enum Values

    func testUnknownCommandTypeFailsGracefully() {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "command": "rebootIntoRecoveryMode",
            "timestamp": 1700000000.0,
            "validityWindowSeconds": 30.0,
            "parameters": {}
        }
        """
        let data = Data(json.utf8)
        XCTAssertThrowsError(try jsonDecoder.decode(CommandMessage.self, from: data)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                XCTFail("Expected dataCorrupted for unknown enum, got \(error)")
                return
            }
            XCTAssertTrue(context.codingPath.contains(where: { $0.stringValue == "command" }))
        }
    }

    func testUnknownDeviceTypeFailsGracefully() {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "publicKeyHex": "0123456789abcdef",
            "displayName": "Quantum Cloud Server",
            "deviceType": "quantumServer",
            "modelIdentifier": "QC-1",
            "systemVersion": "1.0",
            "createdAt": 1700000000.0
        }
        """
        let data = Data(json.utf8)
        XCTAssertThrowsError(try jsonDecoder.decode(DeviceIdentity.self, from: data)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                XCTFail("Expected dataCorrupted for unknown deviceType, got \(error)")
                return
            }
            XCTAssertTrue(context.codingPath.contains(where: { $0.stringValue == "deviceType" }))
        }
    }

    func testUnknownCapabilityInTrustRecordFailsGracefully() {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "peer": {
                "id": "\(UUID().uuidString)",
                "publicKeyHex": "0123",
                "displayName": "Mac",
                "deviceType": "mac",
                "modelIdentifier": "Mac15,3",
                "systemVersion": "14.5",
                "createdAt": 1700000000.0
            },
            "pairedAt": 1700000000.0,
            "lastSeenAt": 1700000000.0,
            "isRevoked": false,
            "authorizedCapabilities": ["quantumWipe"]
        }
        """
        let data = Data(json.utf8)
        XCTAssertThrowsError(try jsonDecoder.decode(TrustRecord.self, from: data))
    }

    // MARK: - 5. Unexpected Data Types & Null Values

    func testUnexpectedDataTypes() {
        // String where integer expected
        let badSeqNumber = """
        {
            "version": 1,
            "id": "\(UUID().uuidString)",
            "senderPublicKeyHex": "0123",
            "recipientPublicKeyHex": "4567",
            "sequenceNumber": "one-hundred",
            "timestampMilliseconds": 1700000000000,
            "nonceHex": "0011",
            "ciphertextHex": "aabb",
            "authTagHex": "ccdd",
            "signatureHex": "eeff"
        }
        """
        XCTAssertThrowsError(try jsonDecoder.decode(CommandEnvelope.self, from: Data(badSeqNumber.utf8)))

        // Array where object expected
        let badIdentity = """
        {
            "invitationId": "\(UUID().uuidString)",
            "clientIdentity": ["array", "not", "object"],
            "clientEphemeralPublicKeyHex": "ccdd",
            "nonceProofHex": "eeff"
        }
        """
        XCTAssertThrowsError(try jsonDecoder.decode(PairingRequest.self, from: Data(badIdentity.utf8)))

        // Boolean where dictionary expected
        let badParams = """
        {
            "id": "\(UUID().uuidString)",
            "command": "lockScreen",
            "timestamp": 1700000000.0,
            "validityWindowSeconds": 30.0,
            "parameters": true
        }
        """
        XCTAssertThrowsError(try jsonDecoder.decode(CommandMessage.self, from: Data(badParams.utf8)))
    }

    func testNullValuesRejectedForNonOptionals() {
        let nullId = """
        {
            "version": 1,
            "id": null,
            "senderPublicKeyHex": "0123",
            "recipientPublicKeyHex": "4567",
            "sequenceNumber": 1,
            "timestampMilliseconds": 1700000000000,
            "nonceHex": "0011",
            "ciphertextHex": "aabb",
            "authTagHex": "ccdd",
            "signatureHex": "eeff"
        }
        """
        XCTAssertThrowsError(try jsonDecoder.decode(CommandEnvelope.self, from: Data(nullId.utf8)))

        let nullCommand = """
        {
            "id": "\(UUID().uuidString)",
            "command": null,
            "timestamp": 1700000000.0,
            "validityWindowSeconds": 30.0,
            "parameters": {}
        }
        """
        XCTAssertThrowsError(try jsonDecoder.decode(CommandMessage.self, from: Data(nullCommand.utf8)))
    }

    // MARK: - 6. Oversized Inputs (DoS Resistance)

    func testOversizedStringsDoNotCrash() throws {
        // 100 KB string
        let largeString100K = String(repeating: "A", count: 100_000)
        let device = DeviceIdentity(
            publicKeyHex: largeString100K,
            displayName: "Test Device",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "18.0"
        )

        let encoded = try JSONEncoder().encode(device)
        let decoded = try jsonDecoder.decode(DeviceIdentity.self, from: encoded)
        XCTAssertEqual(decoded.publicKeyHex.count, 100_000)

        // 1 MB string in parameters dictionary
        let largeString1M = String(repeating: "X", count: 1_000_000)
        let message = CommandMessage(
            command: .lockScreen,
            parameters: ["payload": largeString1M]
        )
        let encodedMessage = try JSONEncoder().encode(message)
        let decodedMessage = try jsonDecoder.decode(CommandMessage.self, from: encodedMessage)
        XCTAssertEqual(decodedMessage.parameters["payload"]?.count, 1_000_000)
    }

    // MARK: - 7. Invalid UUIDs

    func testInvalidUUIDStringsRejected() {
        let invalidUUIDs = [
            "not-a-uuid",
            "",
            "12345",
            "00000000-0000-0000-0000-0000000000001",
            "g0000000-0000-0000-0000-000000000000",
            "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        ]

        for invalid in invalidUUIDs {
            let json = """
            {
                "id": "\(invalid)",
                "publicKeyHex": "0123",
                "displayName": "Device",
                "deviceType": "mac",
                "modelIdentifier": "Mac15,3",
                "systemVersion": "14.5",
                "createdAt": 1700000000.0
            }
            """
            XCTAssertThrowsError(try jsonDecoder.decode(DeviceIdentity.self, from: Data(json.utf8)),
                                 "Should reject invalid UUID: \(invalid)")
        }
    }

    // MARK: - 8. Invalid and Extreme Timestamps

    func testExtremeTimestampsFailSafely() {
        // Negative timestamp before Unix epoch
        XCTAssertFalse(HandshakeTime.isTimestampValid(-1000))
        XCTAssertFalse(HandshakeTime.isTimestampValid(Int64.min))

        // Extreme future timestamp
        XCTAssertFalse(HandshakeTime.isTimestampValid(Int64.max))
        XCTAssertFalse(HandshakeTime.isTimestampValid(9_999_999_999_999_999))

        // Non-finite and extreme Dates in CommandMessage
        let nanDate = Date(timeIntervalSince1970: .nan)
        let nanMessage = CommandMessage(command: .lockScreen, timestamp: nanDate)
        XCTAssertTrue(nanMessage.isExpired(), "NaN timestamp must be treated as expired")

        let infinityDate = Date(timeIntervalSince1970: .infinity)
        let infMessage = CommandMessage(command: .lockScreen, timestamp: infinityDate)
        XCTAssertTrue(infMessage.isExpired(), "Infinite timestamp must be treated as expired")

        let distantPastMessage = CommandMessage(command: .lockScreen, timestamp: Date.distantPast)
        XCTAssertTrue(distantPastMessage.isExpired(), "Distant past message must be expired")

        let distantFutureMessage = CommandMessage(command: .lockScreen, timestamp: Date.distantFuture)
        XCTAssertTrue(distantFutureMessage.isExpired(), "Future skew message must be expired")
    }

    func testPairingInvitationResilienceToExtremeDates() {
        let host = DeviceIdentity(
            publicKeyHex: "0123456789abcdef",
            displayName: "Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "14.5"
        )

        // Far future date does not cause integer overflow in QR string or remaining seconds
        let farFuture = Date(timeIntervalSince1970: 1e20)
        let invitation = PairingInvitation(
            hostIdentity: host,
            ephemeralPublicKeyHex: "fedc",
            createdAt: farFuture,
            lifetimeSeconds: 1000
        )

        // remainingSeconds must cap at Int.max or return safely without crash
        let remaining = invitation.remainingSeconds(at: Date())
        XCTAssertGreaterThanOrEqual(remaining, 0)

        // qrPayloadString must not trap on conversion
        let qr = invitation.qrPayloadString
        XCTAssertFalse(qr.isEmpty)
        XCTAssertTrue(qr.contains("handshake://pair"))
    }

    // MARK: - 9. Unexpected Protocol Versions

    func testUnexpectedProtocolVersions() {
        // Incompatible future major version
        let v2 = ProtocolVersion(major: 2, minor: 0)
        XCTAssertFalse(v2.isCompatible)

        // Incompatible legacy major version
        let v0 = ProtocolVersion(major: 0, minor: 9)
        XCTAssertFalse(v0.isCompatible)

        // Future minor version (same major) is forward compatible under standard semver
        let v1_5 = ProtocolVersion(major: 1, minor: 5)
        XCTAssertTrue(v1_5.isCompatible)

        // Decoding negative version numbers from JSON fails
        let negativeVersionJson = "{\"major\": -1, \"minor\": 0}"
        XCTAssertThrowsError(try jsonDecoder.decode(ProtocolVersion.self, from: Data(negativeVersionJson.utf8)))
    }
}
