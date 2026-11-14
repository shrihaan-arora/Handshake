import XCTest
@testable import HandshakeCore

final class SecurityBoundaryTests: XCTestCase {

    // MARK: - Pairing Invitation Expiration & Boundaries

    func testPairingInvitationExactBoundaries() {
        let baseDate = Date()
        let host = DeviceIdentity(
            publicKeyHex: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            displayName: "Test Host Mac",
            deviceType: .mac,
            modelIdentifier: "Mac15,3",
            systemVersion: "macOS 14.5",
            createdAt: baseDate
        )

        let lifetime: TimeInterval = 60.0
        let invitation = PairingInvitation(
            hostIdentity: host,
            ephemeralPublicKeyHex: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
            createdAt: baseDate,
            lifetimeSeconds: lifetime
        )

        // 1 millisecond before expiration -> NOT expired
        let justBefore = invitation.expiresAt.addingTimeInterval(-0.001)
        XCTAssertFalse(invitation.isExpired(at: justBefore))

        // Exact expiration instant -> NOT expired (date > expiresAt is false when equal)
        XCTAssertFalse(invitation.isExpired(at: invitation.expiresAt))

        // 1 millisecond after expiration -> IS expired
        let justAfter = invitation.expiresAt.addingTimeInterval(0.001)
        XCTAssertTrue(invitation.isExpired(at: justAfter))

        // Remaining seconds check
        XCTAssertEqual(invitation.remainingSeconds(at: baseDate), 60)
        XCTAssertEqual(invitation.remainingSeconds(at: baseDate.addingTimeInterval(30)), 30)
        XCTAssertEqual(invitation.remainingSeconds(at: invitation.expiresAt), 0)
        XCTAssertEqual(invitation.remainingSeconds(at: baseDate.addingTimeInterval(120)), 0)
    }

    func testInvitationReusedAndSingleUseConsumption() {
        // Simulating the host invitation consumption state machine
        var activeInvitations: [UUID: PairingInvitation] = [:]
        var consumedInvitationIDs: Set<UUID> = []

        let host = DeviceIdentity(
            publicKeyHex: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
            displayName: "Mac Host",
            deviceType: .mac,
            modelIdentifier: "MacBookPro18,1",
            systemVersion: "macOS 14.0"
        )

        let invitation = PairingInvitation(
            hostIdentity: host,
            ephemeralPublicKeyHex: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
            lifetimeSeconds: 120
        )
        activeInvitations[invitation.id] = invitation

        enum PairingAttemptError: Error {
            case alreadyConsumed
            case notFound
            case expired
        }

        // Helper state machine transition
        func processPairingAttempt(invitationId: UUID, at date: Date = Date()) -> Result<PairingInvitation, PairingAttemptError> {
            if consumedInvitationIDs.contains(invitationId) {
                return .failure(.alreadyConsumed)
            }
            guard let inv = activeInvitations[invitationId] else {
                return .failure(.notFound)
            }
            if inv.isExpired(at: date) {
                return .failure(.expired)
            }
            // Mark consumed
            activeInvitations.removeValue(forKey: invitationId)
            consumedInvitationIDs.insert(invitationId)
            return .success(inv)
        }

        // 1. First attempt should succeed
        let attempt1 = processPairingAttempt(invitationId: invitation.id)
        switch attempt1 {
        case .success(let matched):
            XCTAssertEqual(matched.id, invitation.id)
        case .failure(let err):
            XCTFail("First pairing attempt failed: \(err)")
        }

        // 2. Second attempt with the SAME invitation must fail (Reused invitation attack)
        let attempt2 = processPairingAttempt(invitationId: invitation.id)
        switch attempt2 {
        case .success:
            XCTFail("Reused invitation was incorrectly accepted")
        case .failure(let err):
            XCTAssertEqual(err, .alreadyConsumed)
        }

        // 3. Attempt with an expired invitation must fail
        let expiredInv = PairingInvitation(
            hostIdentity: host,
            ephemeralPublicKeyHex: "aaaa",
            createdAt: Date().addingTimeInterval(-200),
            lifetimeSeconds: 60
        )
        activeInvitations[expiredInv.id] = expiredInv

        let attemptExpired = processPairingAttempt(invitationId: expiredInv.id)
        switch attemptExpired {
        case .success:
            XCTFail("Expired invitation was incorrectly accepted")
        case .failure(let err):
            XCTAssertEqual(err, .expired)
        }
    }

    // MARK: - Command Timestamp & Clock Skew Boundaries

    func testCommandTimestampPreciseBoundaries() {
        let reference = Date()
        let refMs = Int64(reference.timeIntervalSince1970 * 1000)

        // Exact match
        XCTAssertTrue(HandshakeTime.isTimestampValid(refMs, referenceTime: reference))

        // Exactly 30.000 seconds past (allowed by <= 30.0)
        let exactly30sPast = refMs - 30_000
        XCTAssertTrue(HandshakeTime.isTimestampValid(exactly30sPast, referenceTime: reference))

        // 30.001 seconds past (must be rejected)
        let past30sAnd1ms = refMs - 30_001
        XCTAssertFalse(HandshakeTime.isTimestampValid(past30sAnd1ms, referenceTime: reference))

        // Exactly 30.000 seconds future
        let exactly30sFuture = refMs + 30_000
        XCTAssertTrue(HandshakeTime.isTimestampValid(exactly30sFuture, referenceTime: reference))

        // 30.001 seconds future (rejected)
        let future30sAnd1ms = refMs + 30_001
        XCTAssertFalse(HandshakeTime.isTimestampValid(future30sAnd1ms, referenceTime: reference))

        // Custom skew threshold test
        XCTAssertTrue(HandshakeTime.isTimestampValid(refMs - 5_000, referenceTime: reference, maxSkew: 5.0))
        XCTAssertFalse(HandshakeTime.isTimestampValid(refMs - 5_001, referenceTime: reference, maxSkew: 5.0))
    }

    func testCommandMessageExpirationSkew() {
        let now = Date()

        // Default validity window is 30s
        let msg = CommandMessage(command: .lockScreen, timestamp: now, validityWindowSeconds: 30)
        XCTAssertFalse(msg.isExpired(at: now))

        // Boundary: 29.9s later -> not expired
        XCTAssertFalse(msg.isExpired(at: now.addingTimeInterval(29.9)))

        // Boundary: 30.1s later -> expired
        XCTAssertTrue(msg.isExpired(at: now.addingTimeInterval(30.1)))

        // Negative age (future clock skew): up to 5s future is tolerated
        XCTAssertFalse(msg.isExpired(at: now.addingTimeInterval(-4.9)))

        // Future clock skew beyond 5s (e.g., 5.1s) -> treated as expired/invalid
        XCTAssertTrue(msg.isExpired(at: now.addingTimeInterval(-5.1)))
    }

    // MARK: - Sequence Counter Replay Window Boundaries

    func testSequenceCounterWindowBoundaryExhaustion() async {
        let counter = SequenceCounter()

        // Feed sequences 1 through 1000
        for seq in 1...1000 {
            let accepted = await counter.validateAndAcceptIncoming(UInt64(seq))
            XCTAssertTrue(accepted, "Sequence \(seq) should be accepted")
        }

        // All 1...1000 should now be rejected if replayed
        for replay in [1, 50, 500, 999, 1000] {
            let replayed = await counter.validateAndAcceptIncoming(UInt64(replay))
            XCTAssertFalse(replayed, "Replay of sequence \(replay) must be rejected")
        }

        // Now advance highest sequence to 2000
        let advanced = await counter.validateAndAcceptIncoming(2000)
        XCTAssertTrue(advanced)

        // The window size is 1000, so valid window is now (2000 - 1000) = 1000...2000
        // Sequence 999 is outside window -> must be rejected as too old
        let oldSeq = await counter.validateAndAcceptIncoming(999)
        XCTAssertFalse(oldSeq, "Sequence 999 should be rejected because it fell outside the sliding window")

        // Sequence 1000 is on the boundary -> rejected (outside window threshold)
        let boundarySeq = await counter.validateAndAcceptIncoming(1000)
        XCTAssertFalse(boundarySeq)

        // Sequence 1500 was never seen and is within (1000, 2000) -> must be accepted!
        let unseenInWindow = await counter.validateAndAcceptIncoming(1500)
        XCTAssertTrue(unseenInWindow, "Unseen sequence 1500 inside window should be accepted")

        // Now replay 1500 -> must be rejected
        let replay1500 = await counter.validateAndAcceptIncoming(1500)
        XCTAssertFalse(replay1500, "Replayed sequence 1500 must be rejected")
    }

    func testSequenceCounterLargeJumpAndReset() async {
        let counter = SequenceCounter()

        // Accept a large sequence jump (e.g. peer sent 5000)
        let jump = await counter.validateAndAcceptIncoming(5000)
        XCTAssertTrue(jump)

        // Anything below 4000 (5000 - 1000) must be rejected
        let tooOld = await counter.validateAndAcceptIncoming(3999)
        XCTAssertFalse(tooOld)

        // Session re-keying / reset
        await counter.reset(initialCounter: 100)
        let nextOut = await counter.nextOutgoing()
        XCTAssertEqual(nextOut, 101)

        // After reset, sequence 1 should be accepted afresh
        let postReset = await counter.validateAndAcceptIncoming(1)
        XCTAssertTrue(postReset)
    }

    // MARK: - Malformed Input Handling

    func testMalformedJSONDeserialization() {
        let invalidData = "This is not json".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(CommandMessage.self, from: invalidData))
        XCTAssertThrowsError(try JSONDecoder().decode(CommandEnvelope.self, from: invalidData))
        XCTAssertThrowsError(try JSONDecoder().decode(DeviceIdentity.self, from: invalidData))
        XCTAssertThrowsError(try JSONDecoder().decode(PairingInvitation.self, from: invalidData))

        // Missing required field
        let partialJSON = """
        {
            "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            "command": "lock_screen"
        }
        """.data(using: .utf8)!

        // CommandMessage requires timestamp, validityWindowSeconds, parameters
        XCTAssertThrowsError(try JSONDecoder().decode(CommandMessage.self, from: partialJSON))
    }

    func testCorruptedEnvelopeTampering() throws {
        let original = CommandEnvelope(
            version: 1,
            id: UUID(),
            senderPublicKeyHex: "010203040506",
            recipientPublicKeyHex: "0708090a0b0c",
            sequenceNumber: 77,
            timestampMilliseconds: 1700000000000,
            nonceHex: "00112233445566778899aabb",
            ciphertextHex: "deadbeefcafebabe",
            authTagHex: "1234567890abcdef1234567890abcdef",
            signatureHex: "sig"
        )

        let encoded = try JSONEncoder().encode(original)
        var jsonString = String(data: encoded, encoding: .utf8)!

        // Tamper with sequence number in transit
        jsonString = jsonString.replacingOccurrences(of: "\"sequenceNumber\":77", with: "\"sequenceNumber\":78")
        let tamperedData = jsonString.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: tamperedData)
        XCTAssertEqual(decoded.sequenceNumber, 78)
        // Ensure associated data payload detects change:
        XCTAssertNotEqual(original.associatedDataPayload, decoded.associatedDataPayload)
    }

    // MARK: - Device Trust & Capability Revocation

    func testDeviceTrustStateTransitions() {
        let peer = DeviceIdentity(
            publicKeyHex: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
            displayName: "Untrusted Phone",
            deviceType: .iPhone,
            modelIdentifier: "iPhone15,2",
            systemVersion: "iOS 17.4"
        )

        var trust = TrustRecord(
            peer: peer,
            authorizedCapabilities: [.ping, .queryStatus] // Restricted capabilities
        )

        XCTAssertFalse(trust.isRevoked)
        XCTAssertEqual(trust.authorizedCapabilities.count, 2)
        XCTAssertTrue(trust.authorizedCapabilities.contains(.ping))
        XCTAssertFalse(trust.authorizedCapabilities.contains(.lockScreen))
        XCTAssertFalse(trust.authorizedCapabilities.contains(.sleep))

        // Revoke
        trust.revoke()
        XCTAssertTrue(trust.isRevoked)
        XCTAssertNotNil(trust.revokedAt)

        // Revoke again (idempotent)
        let firstRevokedAt = trust.revokedAt
        trust.revoke()
        XCTAssertTrue(trust.isRevoked)
        XCTAssertNotNil(trust.revokedAt)
        XCTAssertEqual(trust.revokedAt, firstRevokedAt)
    }
}
