import XCTest
@testable import HandshakeCore

final class ReplayAndSequenceTests: XCTestCase {

    // MARK: - 1. Monotonicity and Duplication Rejection

    func testMonotonicAndDuplicateSequences() async {
        let counter = SequenceCounter()

        // 1. Initial outgoing increments strictly monotonically
        let first = await counter.nextOutgoing()
        let second = await counter.nextOutgoing()
        let third = await counter.nextOutgoing()

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(third, 3)

        // 2. Incoming sequences
        let accept1 = await counter.validateAndAcceptIncoming(1)
        XCTAssertTrue(accept1)

        // Replay of sequence 1 must fail
        let replay1 = await counter.validateAndAcceptIncoming(1)
        XCTAssertFalse(replay1, "Duplicate sequence 1 must be rejected")

        // Sequence 2 accepted
        let accept2 = await counter.validateAndAcceptIncoming(2)
        XCTAssertTrue(accept2)

        // Replay of sequence 2 must fail
        let replay2 = await counter.validateAndAcceptIncoming(2)
        XCTAssertFalse(replay2, "Duplicate sequence 2 must be rejected")
    }

    // MARK: - 2. Out-of-Order and Replayed Packets Within Window

    func testOutOfOrderAndReplayDetection() async {
        let counter = SequenceCounter()

        // Arrive in scattered order: 10, then 5, then 8, then 2
        let accept10 = await counter.validateAndAcceptIncoming(10)
        XCTAssertTrue(accept10, "Highest seen becomes 10")

        let accept5 = await counter.validateAndAcceptIncoming(5)
        XCTAssertTrue(accept5, "5 is within window of 10, should be accepted")

        let accept8 = await counter.validateAndAcceptIncoming(8)
        XCTAssertTrue(accept8, "8 is within window of 10, should be accepted")

        let accept2 = await counter.validateAndAcceptIncoming(2)
        XCTAssertTrue(accept2, "2 is within window of 10, should be accepted")

        // Now test replaying those same scattered packets
        let replay5 = await counter.validateAndAcceptIncoming(5)
        XCTAssertFalse(replay5, "Replay of 5 must be rejected")

        let replay8 = await counter.validateAndAcceptIncoming(8)
        XCTAssertFalse(replay8, "Replay of 8 must be rejected")

        let replay10 = await counter.validateAndAcceptIncoming(10)
        XCTAssertFalse(replay10, "Replay of 10 must be rejected")

        // New higher sequence 11 accepted
        let accept11 = await counter.validateAndAcceptIncoming(11)
        XCTAssertTrue(accept11)
    }

    // MARK: - 3. Sliding-Window Boundaries (Window Size = 1000)

    func testSlidingWindowExactBoundaries() async {
        let counter = SequenceCounter()

        // Advance highest seen sequence to 2000
        let accept2000 = await counter.validateAndAcceptIncoming(2000)
        XCTAssertTrue(accept2000)

        // The replayWindowSize is 1000.
        // Within window: highestIncomingSequence - sequenceNumber < 1000
        // 2000 - 1001 = 999 (< 1000) -> ACCEPTED
        let accept1001 = await counter.validateAndAcceptIncoming(1001)
        XCTAssertTrue(accept1001, "Sequence 1001 is within 1000-frame window of 2000")

        // Replay of 1001 -> REJECTED
        let replay1001 = await counter.validateAndAcceptIncoming(1001)
        XCTAssertFalse(replay1001)

        // 2000 - 1000 = 1000 (NOT < 1000) -> OUTSIDE WINDOW -> REJECTED
        let reject1000 = await counter.validateAndAcceptIncoming(1000)
        XCTAssertFalse(reject1000, "Sequence 1000 is on/outside the 1000-frame window boundary")

        // Older sequences -> REJECTED
        let reject999 = await counter.validateAndAcceptIncoming(999)
        XCTAssertFalse(reject999)

        let reject1 = await counter.validateAndAcceptIncoming(1)
        XCTAssertFalse(reject1)
    }

    // MARK: - 4. Counter Overflow and Extreme Boundaries

    func testCounterOverflowSafety() async {
        // Test 1: Outgoing counter initialized near UInt64.max
        let counterNearMax = SequenceCounter(initialCounter: UInt64.max - 1)
        let maxSeq = await counterNearMax.nextOutgoing()
        XCTAssertEqual(maxSeq, UInt64.max)

        // Subsequent increment must saturate safely and not crash with arithmetic overflow
        let saturatedSeq = await counterNearMax.nextOutgoing()
        XCTAssertEqual(saturatedSeq, UInt64.max)

        // Test 2: Incoming zero sequence number must be rejected
        let counterIncoming = SequenceCounter()
        let rejectZero = await counterIncoming.validateAndAcceptIncoming(0)
        XCTAssertFalse(rejectZero, "Sequence number 0 must be rejected")

        // Test 3: Incoming extreme sequence near UInt64.max
        let extremeSeq = UInt64.max - 5
        let acceptExtreme = await counterIncoming.validateAndAcceptIncoming(extremeSeq)
        XCTAssertTrue(acceptExtreme)

        // Test 4: Incoming out-of-order sequence near UInt64.max
        // This validates our overflow fix (preventing arithmetic overflow on sequenceNumber + replayWindowSize)
        let extremeOutOfOrder = UInt64.max - 10
        let acceptOutOfOrder = await counterIncoming.validateAndAcceptIncoming(extremeOutOfOrder)
        XCTAssertTrue(acceptOutOfOrder, "Extreme out-of-order frame must not trigger arithmetic overflow")

        // Replay of that extreme frame must be safely rejected
        let replayExtreme = await counterIncoming.validateAndAcceptIncoming(extremeOutOfOrder)
        XCTAssertFalse(replayExtreme)
    }

    // MARK: - 5. Concurrent Sequence Requests (Actor Isolation & Thread Safety)

    func testConcurrentSequenceGeneration() async {
        let counter = SequenceCounter()
        let taskCount = 100

        // Launch 100 concurrent async tasks requesting next outgoing sequence
        let generatedSequences: [UInt64] = await withTaskGroup(of: UInt64.self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    await counter.nextOutgoing()
                }
            }
            var results: [UInt64] = []
            for await seq in group {
                results.append(seq)
            }
            return results
        }

        XCTAssertEqual(generatedSequences.count, taskCount)

        // Verify all 100 sequence numbers are strictly unique (no duplicates from race conditions)
        let uniqueSequences = Set(generatedSequences)
        XCTAssertEqual(uniqueSequences.count, taskCount, "All concurrently generated sequences must be unique")

        // Verify they span 1...100
        let minSeq = generatedSequences.min() ?? 0
        let maxSeq = generatedSequences.max() ?? 0
        XCTAssertEqual(minSeq, 1)
        XCTAssertEqual(maxSeq, UInt64(taskCount))
    }

    // MARK: - 6. Session Reset and Session Isolation

    func testSessionResetAndMultiSessionIsolation() async {
        let sessionA = SequenceCounter()
        let sessionB = SequenceCounter()

        // Advance session A to 50
        for _ in 1...50 {
            _ = await sessionA.nextOutgoing()
        }
        let aIncoming = await sessionA.validateAndAcceptIncoming(100)
        XCTAssertTrue(aIncoming)

        // Session B must remain completely untouched at 0
        let bFirst = await sessionB.nextOutgoing()
        XCTAssertEqual(bFirst, 1, "Session B must have its own isolated sequence space")

        let bIncoming = await sessionB.validateAndAcceptIncoming(100)
        XCTAssertTrue(bIncoming, "Session B accepts 100 independently of Session A")

        // Reset session A
        await sessionA.reset(initialCounter: 0)

        // After reset, session A can start fresh at sequence 1
        let aNextAfterReset = await sessionA.nextOutgoing()
        XCTAssertEqual(aNextAfterReset, 1)

        let aIncomingAfterReset = await sessionA.validateAndAcceptIncoming(1)
        XCTAssertTrue(aIncomingAfterReset, "Sequence 1 is accepted again after session reset")
    }
}
