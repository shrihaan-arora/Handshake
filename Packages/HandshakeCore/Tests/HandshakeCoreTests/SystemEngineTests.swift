import XCTest
@testable import HandshakeCore

final class SystemEngineTests: XCTestCase {

    #if os(macOS)
    func testMacLockEngineExecutionStateSemantics() async {
        let lockEngine = MacLockEngine()

        // Verify state properties
        XCTAssertTrue(MacLockEngine.LockExecutionState.invoked.isSuccess)
        XCTAssertTrue(MacLockEngine.LockExecutionState.confirmedLocked.isSuccess)
        XCTAssertFalse(MacLockEngine.LockExecutionState.received.isSuccess)
        XCTAssertFalse(MacLockEngine.LockExecutionState.authenticated.isSuccess)
        XCTAssertFalse(MacLockEngine.LockExecutionState.failed("Denied").isSuccess)

        // Verify verification query executes safely without throwing or crashing
        let isRunning = await lockEngine.verifyScreenSaverActive()
        // In automated test runner, screen saver is typically false
        XCTAssertFalse(isRunning)
    }

    func testMacSleepEngineSupportAndSemantics() {
        let sleepEngine = MacSleepEngine()

        // IOPMSleepEnabled should return true on physical macOS hardware
        let supported = sleepEngine.isSleepSupported()
        XCTAssertTrue(supported, "macOS host should report sleep supported")

        // Verify state properties
        XCTAssertTrue(MacSleepEngine.SleepExecutionState.sleepInitiated.isSuccess)
        XCTAssertTrue(MacSleepEngine.SleepExecutionState.acknowledgmentFlushed.isSuccess)
        XCTAssertFalse(MacSleepEngine.SleepExecutionState.received.isSuccess)
        XCTAssertFalse(MacSleepEngine.SleepExecutionState.authenticated.isSuccess)
        XCTAssertFalse(MacSleepEngine.SleepExecutionState.sleepNotSupported.isSuccess)
        XCTAssertFalse(MacSleepEngine.SleepExecutionState.failed("Error").isSuccess)
    }
    #endif

    func testCommandAcknowledgmentExecutionStatusSemantics() {
        let received = CommandAcknowledgment.ExecutionStatus.received
        let executed = CommandAcknowledgment.ExecutionStatus.executed
        let rejected = CommandAcknowledgment.ExecutionStatus.rejected("Not authorized")
        let failed = CommandAcknowledgment.ExecutionStatus.failed("Hardware error")

        XCTAssertEqual(received, CommandAcknowledgment.ExecutionStatus.received)
        XCTAssertEqual(executed, CommandAcknowledgment.ExecutionStatus.executed)
        XCTAssertEqual(rejected, CommandAcknowledgment.ExecutionStatus.rejected("Not authorized"))
        XCTAssertEqual(failed, CommandAcknowledgment.ExecutionStatus.failed("Hardware error"))
    }
}
