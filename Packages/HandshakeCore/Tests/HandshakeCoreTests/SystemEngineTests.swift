import XCTest
import CryptoKit
@testable import HandshakeCore

final class SystemEngineTests: XCTestCase {

    #if os(macOS)
    func testMacLockEngineExecutionStateSemantics() async {
        let lockEngine = MacLockEngine()

        // Verify state properties
        XCTAssertTrue(MacLockEngine.LockExecutionState.invoked.isSuccess)
        XCTAssertTrue(MacLockEngine.LockExecutionState.confirmedLocked.isSuccess)
        XCTAssertTrue(MacLockEngine.LockExecutionState.confirmedLocked(passwordRequiredImmediately: true).isSuccess)
        XCTAssertFalse(MacLockEngine.LockExecutionState.confirmedLocked(passwordRequiredImmediately: false).isSuccess)
        XCTAssertFalse(MacLockEngine.LockExecutionState.received.isSuccess)
        XCTAssertFalse(MacLockEngine.LockExecutionState.authenticated.isSuccess)
        XCTAssertFalse(MacLockEngine.LockExecutionState.failed("Denied").isSuccess)

        // Verify verification query executes safely without throwing or crashing
        let isRunning = await lockEngine.verifyScreenSaverActive()
        // In automated test runner, screen saver is typically false
        XCTAssertFalse(isRunning)
    }

    func testSysadminctlOutputParsing() {
        // 1. Immediate setting
        let immediateOutput1 = "2026-11-15 04:57:42.021 sysadminctl[21025:241467] screenLock delay is immediate\n"
        let parsed1 = MacLockEngine.parseSysadminctlOutput(immediateOutput1)
        XCTAssertEqual(parsed1, .immediate)
        XCTAssertTrue(parsed1.isSecure)
        XCTAssertTrue(parsed1.description.contains("Immediately"))

        let immediateOutput2 = "screenLock delay is immediate"
        XCTAssertEqual(MacLockEngine.parseSysadminctlOutput(immediateOutput2), .immediate)

        // 2. Delayed settings
        let delayedOutput1 = "2026-11-15 04:57:42.021 sysadminctl[21025:241467] screenLock delay is 300 seconds\n"
        let parsedDelayed = MacLockEngine.parseSysadminctlOutput(delayedOutput1)
        XCTAssertEqual(parsedDelayed, .delayed(seconds: 300))
        XCTAssertFalse(parsedDelayed.isSecure)
        XCTAssertTrue(parsedDelayed.description.contains("5m delay"))

        let shortDelayedOutput = "screenLock delay is 5 seconds"
        let parsedShort = MacLockEngine.parseSysadminctlOutput(shortDelayedOutput)
        XCTAssertEqual(parsedShort, .delayed(seconds: 5))
        XCTAssertFalse(parsedShort.isSecure)
        XCTAssertTrue(parsedShort.description.contains("5s delay"))

        // 3. Disabled setting
        let disabledOutput = "screenLock is off\n"
        let parsedDisabled = MacLockEngine.parseSysadminctlOutput(disabledOutput)
        XCTAssertEqual(parsedDisabled, .disabled)
        XCTAssertFalse(parsedDisabled.isSecure)
        XCTAssertTrue(parsedDisabled.description.contains("Disabled"))

        // 4. Empty and unrecognized outputs
        let emptyOutput = "   \n"
        let parsedEmpty = MacLockEngine.parseSysadminctlOutput(emptyOutput)
        guard case .unverified = parsedEmpty else {
            XCTFail("Empty output should parse as unverified")
            return
        }

        let strangeOutput = "Permission denied or unexpected response"
        let parsedStrange = MacLockEngine.parseSysadminctlOutput(strangeOutput)
        guard case .unverified(let reason) = parsedStrange else {
            XCTFail("Unrecognized output should parse as unverified")
            return
        }
        XCTAssertTrue(reason.contains("unexpected response"))
    }

    @MainActor
    func testMacLockEngineRejectsLockWhenGracePeriodNotImmediate() async {
        // Mock engine with delayed grace period (5 minutes)
        let delayedEngine = MacLockEngine(gracePeriodProvider: {
            .delayed(seconds: 300)
        })
        let delayedResult = await delayedEngine.lockDisplay()
        guard case .failed(let reason) = delayedResult else {
            XCTFail("Lock must fail when grace period is not immediate, got \(delayedResult)")
            return
        }
        XCTAssertTrue(reason.contains("grace period is not set to 'Immediately'"))

        // Mock engine with disabled grace period
        let disabledEngine = MacLockEngine(gracePeriodProvider: {
            .disabled
        })
        let disabledResult = await disabledEngine.lockDisplay()
        guard case .failed(let reason) = disabledResult else {
            XCTFail("Lock must fail when password is off, got \(disabledResult)")
            return
        }
        XCTAssertTrue(reason.contains("grace period is not set to 'Immediately'"))
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

    func testCommandReceiptModelAndSignature() throws {
        let client = try CryptoIdentity.createNew(
            label: "test.receipt.client",
            displayName: "Test Client iPhone",
            deviceType: .iPhone,
            modelIdentifier: "iPhone16,1",
            systemVersion: "18.0",
            preferSecureEnclave: false
        )

        let cmdId = UUID()
        let receiptPlaceholder = CommandReceipt(commandId: cmdId, clientIdentity: client.identity)
        let signature = try client.sign(data: receiptPlaceholder.signablePayload)

        let signedReceipt = CommandReceipt(
            commandId: cmdId,
            timestampMilliseconds: receiptPlaceholder.timestampMilliseconds,
            clientIdentity: client.identity,
            signatureHex: signature.hexString
        )

        // Verify Codable round-trip
        let data = try JSONEncoder().encode(signedReceipt)
        let decoded = try JSONDecoder().decode(CommandReceipt.self, from: data)

        XCTAssertEqual(decoded.commandId, cmdId)
        XCTAssertEqual(decoded.clientIdentity.publicKeyHex, client.identity.publicKeyHex)
        XCTAssertEqual(decoded.signatureHex, signature.hexString)

        // Verify signature verification
        let sigData = try XCTUnwrap(Data(hexString: decoded.signatureHex))
        let isValid = CryptoIdentity.verify(
            signatureRaw: sigData,
            for: decoded.signablePayload,
            publicKeyHex: decoded.clientIdentity.publicKeyHex
        )
        XCTAssertTrue(isValid, "CommandReceipt signature must verify against client public key")
    }
}
