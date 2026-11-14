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
}

