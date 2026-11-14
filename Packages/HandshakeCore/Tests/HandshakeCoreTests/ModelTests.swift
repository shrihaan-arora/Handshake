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
