import XCTest
@testable import HandshakeCore

final class EnvelopeTests: XCTestCase {
    func testCommandEnvelopeSerializationAndAssociatedData() {
        let envelope = CommandEnvelope(
            version: 1,
            id: UUID(),
            senderPublicKeyHex: "0102030405",
            recipientPublicKeyHex: "060708090a",
            sequenceNumber: 42,
            timestampMilliseconds: 1700000000000,
            nonceHex: "aabbccddeeff001122334455",
            ciphertextHex: "cafebabe",
            authTagHex: "0123456789abcdef0123456789abcdef",
            signatureHex: "signature"
        )

        let associatedData = envelope.associatedDataPayload
        XCTAssertFalse(associatedData.isEmpty)
        // Ensure associated data includes version byte
        XCTAssertEqual(associatedData.first, 1)

        // JSON encoding roundtrip
        do {
            let encoded = try JSONEncoder().encode(envelope)
            let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: encoded)
            XCTAssertEqual(envelope.id, decoded.id)
            XCTAssertEqual(envelope.sequenceNumber, decoded.sequenceNumber)
            XCTAssertEqual(envelope.senderPublicKeyHex, decoded.senderPublicKeyHex)
        } catch {
            XCTFail("Failed to encode/decode CommandEnvelope: \(error)")
        }
    }

    func testSequenceCounterAntiReplay() async {
        let counter = SequenceCounter()

        // Test outgoing incrementing
        let s1 = await counter.nextOutgoing()
        let s2 = await counter.nextOutgoing()
        let s3 = await counter.nextOutgoing()
        XCTAssertEqual(s1, 1)
        XCTAssertEqual(s2, 2)
        XCTAssertEqual(s3, 3)

        // Test incoming validation
        // Sequence 0 must be rejected
        let zeroValid = await counter.validateAndAcceptIncoming(0)
        XCTAssertFalse(zeroValid)

        // Normal ordered incoming
        let valid1 = await counter.validateAndAcceptIncoming(1)
        XCTAssertTrue(valid1)

        let valid2 = await counter.validateAndAcceptIncoming(2)
        XCTAssertTrue(valid2)

        // Replay of sequence 1 must be rejected
        let replay1 = await counter.validateAndAcceptIncoming(1)
        XCTAssertFalse(replay1)

        // Replay of sequence 2 must be rejected
        let replay2 = await counter.validateAndAcceptIncoming(2)
        XCTAssertFalse(replay2)

        // Out-of-order within acceptable window
        let valid5 = await counter.validateAndAcceptIncoming(5)
        XCTAssertTrue(valid5)

        // 3 and 4 arrived late but still valid
        let valid3 = await counter.validateAndAcceptIncoming(3)
        XCTAssertTrue(valid3)

        // Replay of 3 now rejected
        let replay3 = await counter.validateAndAcceptIncoming(3)
        XCTAssertFalse(replay3)
    }

    func testHandshakeTimeClockSkew() {
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        // Exact match
        XCTAssertTrue(HandshakeTime.isTimestampValid(nowMs, referenceTime: now))

        // 10 seconds in past
        let past10s = nowMs - 10_000
        XCTAssertTrue(HandshakeTime.isTimestampValid(past10s, referenceTime: now))

        // 45 seconds in past (> 30s limit)
        let past45s = nowMs - 45_000
        XCTAssertFalse(HandshakeTime.isTimestampValid(past45s, referenceTime: now))

        // 45 seconds in future (> 30s limit)
        let future45s = nowMs + 45_000
        XCTAssertFalse(HandshakeTime.isTimestampValid(future45s, referenceTime: now))
    }
}
