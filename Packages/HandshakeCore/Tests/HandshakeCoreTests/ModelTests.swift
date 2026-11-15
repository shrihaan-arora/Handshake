import XCTest
@testable import HandshakeCore

final class ModelTests: XCTestCase {
    func testDeviceIdentityCreationAndFingerprint() {
        let identity = DeviceIdentity(
            id: UUID(),
            publicKeyHex: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            displayName: "Test MacBook Pro",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 15.1"
        )

        XCTAssertEqual(identity.displayName, "Test MacBook Pro")
        XCTAssertEqual(identity.deviceType, .mac)
        XCTAssertEqual(identity.shortFingerprint, "E3B0...B855")
        XCTAssertFalse(identity.shortFingerprint.isEmpty)
    }

    func testPairingInvitationExpiration() {
        let host = DeviceIdentity(
            publicKeyHex: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            displayName: "Host Mac",
            deviceType: .mac,
            modelIdentifier: "MacBookPro18,1",
            systemVersion: "macOS 14.0"
        )

        let invitation = PairingInvitation(
            hostIdentity: host,
            ephemeralPublicKeyHex: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
            lifetimeSeconds: 10
        )

        XCTAssertFalse(invitation.isExpired(at: Date()))
        XCTAssertTrue(invitation.isExpired(at: Date().addingTimeInterval(15)))
        XCTAssertTrue(invitation.qrPayloadString.hasPrefix("handshake://pair"))
        XCTAssertTrue(invitation.qrPayloadString.contains("id="))
        XCTAssertTrue(invitation.qrPayloadString.contains("pk="))
    }

    func testPairingInvitationParseValidURL() throws {
        let host = DeviceIdentity(
            publicKeyHex: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            displayName: "Host MacBook Air",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 15.0"
        )

        let original = PairingInvitation(
            hostIdentity: host,
            ephemeralPublicKeyHex: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
            localPort: 5894,
            serviceName: "Handshake-Host",
            lifetimeSeconds: 120,
            verificationCode: "654321"
        )

        let qrString = original.qrPayloadString
        let parsed = try PairingInvitation.parse(from: qrString)

        XCTAssertEqual(parsed.id, original.id)
        XCTAssertEqual(parsed.hostIdentity.displayName, original.hostIdentity.displayName)
        XCTAssertEqual(parsed.hostIdentity.publicKeyHex, original.hostIdentity.publicKeyHex)
        XCTAssertEqual(parsed.ephemeralPublicKeyHex, original.ephemeralPublicKeyHex)
        XCTAssertEqual(parsed.localPort, original.localPort)
        XCTAssertEqual(parsed.nonce, original.nonce)
        XCTAssertEqual(parsed.verificationCode, "654321")
        XCTAssertFalse(parsed.isExpired())
    }

    func testPairingInvitationParseValidJSON() throws {
        let host = DeviceIdentity(
            publicKeyHex: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            displayName: "JSON Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 15.0"
        )

        let original = PairingInvitation(
            hostIdentity: host,
            ephemeralPublicKeyHex: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
            lifetimeSeconds: 60
        )

        let jsonData = try JSONEncoder().encode(original)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        let parsed = try PairingInvitation.parse(from: jsonString)
        XCTAssertEqual(parsed.id, original.id)
        XCTAssertEqual(parsed.hostIdentity.displayName, "JSON Mac")
    }

    func testPairingInvitationRejectsExpired() {
        let host = DeviceIdentity(
            publicKeyHex: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            displayName: "Expired Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 15.0"
        )

        let expired = PairingInvitation(
            hostIdentity: host,
            ephemeralPublicKeyHex: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
            createdAt: Date().addingTimeInterval(-200),
            lifetimeSeconds: 60
        )

        let qrString = expired.qrPayloadString
        XCTAssertThrowsError(try PairingInvitation.parse(from: qrString)) { error in
            guard case PairingInvitationError.expired = error else {
                return XCTFail("Expected .expired error, got: \(error)")
            }
        }
    }

    func testPairingInvitationRejectsInvalidSchemeAndHost() {
        XCTAssertThrowsError(try PairingInvitation.parse(from: "https://example.com/pair?v=1")) { error in
            XCTAssertEqual(error as? PairingInvitationError, .invalidSchemeOrHost)
        }

        XCTAssertThrowsError(try PairingInvitation.parse(from: "handshake://other?v=1")) { error in
            XCTAssertEqual(error as? PairingInvitationError, .invalidSchemeOrHost)
        }
    }

    func testPairingInvitationRejectsUnsupportedVersion() {
        let badVersion = "handshake://pair?v=2&id=\(UUID().uuidString)&name=Mac&pk=0123&epk=0123&port=5894&nonce=123&exp=\(Int(Date().addingTimeInterval(60).timeIntervalSince1970))"
        XCTAssertThrowsError(try PairingInvitation.parse(from: badVersion)) { error in
            XCTAssertEqual(error as? PairingInvitationError, .unsupportedVersion("2"))
        }
    }

    func testPairingInvitationRejectsMissingFields() {
        let missingName = "handshake://pair?v=1&id=\(UUID().uuidString)&pk=0123&epk=0123&port=5894&nonce=123&exp=\(Int(Date().addingTimeInterval(60).timeIntervalSince1970))"
        XCTAssertThrowsError(try PairingInvitation.parse(from: missingName)) { error in
            XCTAssertEqual(error as? PairingInvitationError, .missingRequiredField("name"))
        }
    }

    func testPairingInvitationRejectsInvalidPort() {
        let badPort = "handshake://pair?v=1&id=\(UUID().uuidString)&name=Mac&pk=0123&epk=0123&port=notanumber&nonce=123&exp=\(Int(Date().addingTimeInterval(60).timeIntervalSince1970))"
        XCTAssertThrowsError(try PairingInvitation.parse(from: badPort)) { error in
            XCTAssertEqual(error as? PairingInvitationError, .invalidPort("notanumber"))
        }
    }

    func testPairingInvitationRejectsMalformedData() {
        XCTAssertThrowsError(try PairingInvitation.parse(from: "")) { error in
            XCTAssertEqual(error as? PairingInvitationError, .malformedData)
        }

        XCTAssertThrowsError(try PairingInvitation.parse(from: "   \n  ")) { error in
            XCTAssertEqual(error as? PairingInvitationError, .malformedData)
        }
    }

    func testTrustRecordRevocation() {
        let peer = DeviceIdentity(
            publicKeyHex: "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899",
            displayName: "Test iPhone",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "iOS 18.0"
        )

        var record = TrustRecord(peer: peer)
        XCTAssertFalse(record.isRevoked)
        XCTAssertNil(record.revokedAt)

        record.revoke()
        XCTAssertTrue(record.isRevoked)
        XCTAssertNotNil(record.revokedAt)
    }

    func testConnectionStateProperties() {
        let peer = DeviceIdentity(
            publicKeyHex: "deadbeef",
            displayName: "Studio Mac",
            deviceType: .mac,
            modelIdentifier: "Mac14,13",
            systemVersion: "macOS 14.5"
        )

        let state = ConnectionState.connected(transport: .localWiFi, peer: peer)
        XCTAssertTrue(state.isConnected)
        XCTAssertEqual(state.connectedPeer?.displayName, "Studio Mac")
        XCTAssertEqual(state.transport, .localWiFi)
    }
}
