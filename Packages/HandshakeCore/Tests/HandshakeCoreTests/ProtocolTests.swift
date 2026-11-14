import XCTest
@testable import HandshakeCore

final class ProtocolTests: XCTestCase {
    func testProtocolVersionComparisons() {
        let v1_0 = ProtocolVersion(major: 1, minor: 0)
        let v1_1 = ProtocolVersion(major: 1, minor: 1)
        let v2_0 = ProtocolVersion(major: 2, minor: 0)

        XCTAssertTrue(v1_0.isCompatible)
        XCTAssertTrue(v1_0 < v1_1)
        XCTAssertTrue(v1_1 < v2_0)
        XCTAssertFalse(v2_0.isCompatible)
    }

    func testCommandMessageExpiration() {
        let now = Date()
        let freshCommand = CommandMessage(
            command: .lockScreen,
            timestamp: now,
            validityWindowSeconds: 30
        )
        XCTAssertFalse(freshCommand.isExpired(at: now))

        let expiredCommand = CommandMessage(
            command: .sleep,
            timestamp: now.addingTimeInterval(-35),
            validityWindowSeconds: 30
        )
        XCTAssertTrue(expiredCommand.isExpired(at: now))

        // Skewed into the future (> 5 seconds)
        let futureCommand = CommandMessage(
            command: .lockScreen,
            timestamp: now.addingTimeInterval(10),
            validityWindowSeconds: 30
        )
        XCTAssertTrue(futureCommand.isExpired(at: now))
    }

    func testCommandTypeMetadata() {
        XCTAssertTrue(CommandType.lockScreen.isImpactful)
        XCTAssertTrue(CommandType.sleep.isImpactful)
        XCTAssertFalse(CommandType.ping.isImpactful)
        XCTAssertFalse(CommandType.queryStatus.isImpactful)
    }

    func testCommandMessageAllTypesSerializationRoundTrip() throws {
        for cmdType in CommandType.allCases {
            let cmd = CommandMessage(
                command: cmdType,
                parameters: [
                    "reason": "user_initiated",
                    "unicode": "🔒 MacBook 💤",
                    "symbols": "<>&\"'\\"
                ]
            )

            let data = try JSONEncoder().encode(cmd)
            let decoded = try JSONDecoder().decode(CommandMessage.self, from: data)

            XCTAssertEqual(cmd.id, decoded.id)
            XCTAssertEqual(cmd.command, decoded.command)
            XCTAssertEqual(cmd.parameters["unicode"], "🔒 MacBook 💤")
            XCTAssertEqual(cmd.parameters["symbols"], "<>&\"'\\")
        }
    }

    func testPairingMessagesSerialization() throws {
        let invId = UUID()
        let peer = DeviceIdentity(
            publicKeyHex: "11223344",
            displayName: "Test Client",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,2",
            systemVersion: "iOS 18.0"
        )

        // 1. Request
        let req = PairingRequest(
            invitationId: invId,
            clientIdentity: peer,
            clientEphemeralPublicKeyHex: "aabbcc",
            nonceProofHex: "ddeeff"
        )
        let reqData = try JSONEncoder().encode(PairingMessage.request(req))
        let decodedReq = try JSONDecoder().decode(PairingMessage.self, from: reqData)
        if case .request(let r) = decodedReq {
            XCTAssertEqual(r.invitationId, invId)
            XCTAssertEqual(r.clientIdentity.displayName, "Test Client")
        } else {
            XCTFail("Decoded message was not a request")
        }

        // 2. Response
        let resp = PairingResponse(
            invitationId: invId,
            hostIdentity: peer,
            hostEphemeralPublicKeyHex: "112233",
            sasFingerprintCode: "849201"
        )
        let respData = try JSONEncoder().encode(PairingMessage.response(resp))
        let decodedResp = try JSONDecoder().decode(PairingMessage.self, from: respData)
        if case .response(let r) = decodedResp {
            XCTAssertEqual(r.invitationId, invId)
            XCTAssertEqual(r.sasFingerprintCode, "849201")
        } else {
            XCTFail("Decoded message was not a response")
        }

        // 3. Confirmation
        let conf = PairingConfirmation(
            invitationId: invId,
            isApproved: true,
            confirmedSASCode: "849201"
        )
        let confData = try JSONEncoder().encode(PairingMessage.confirmation(conf))
        let decodedConf = try JSONDecoder().decode(PairingMessage.self, from: confData)
        if case .confirmation(let c) = decodedConf {
            XCTAssertTrue(c.isApproved)
            XCTAssertEqual(c.confirmedSASCode, "849201")
        } else {
            XCTFail("Decoded message was not a confirmation")
        }

        // 4. Completion
        let trust = TrustRecord(peer: peer)
        let comp = PairingCompletion(
            invitationId: invId,
            isSuccessful: true,
            establishedTrustRecord: trust
        )
        let compData = try JSONEncoder().encode(PairingMessage.completion(comp))
        let decodedComp = try JSONDecoder().decode(PairingMessage.self, from: compData)
        if case .completion(let c) = decodedComp {
            XCTAssertTrue(c.isSuccessful)
            XCTAssertEqual(c.establishedTrustRecord?.peer.displayName, "Test Client")
        } else {
            XCTFail("Decoded message was not a completion")
        }
    }
}

