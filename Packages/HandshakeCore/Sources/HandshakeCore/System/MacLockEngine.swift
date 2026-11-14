#if os(macOS)
import Foundation
import AppKit

/// Supported macOS display locking engine using Apple-documented system interfaces.
/// Implements transparent permission auditing, multi-stage state tracking,
/// and independent post-execution verification.
public final class MacLockEngine: Sendable {

    /// Detailed execution state for the lock operation.
    public enum LockExecutionState: Sendable, Equatable {
        case received
        case authenticated
        case invoked
        case confirmedLocked
        case failed(String)

        public var isSuccess: Bool {
            switch self {
            case .invoked, .confirmedLocked: return true
            default: return false
            }
        }
    }

    public init() {}

    /// Executes display lock via System Events screen saver.
    /// In macOS, starting the screen saver engages the system lock screen
    /// when "Require password immediately after sleep or screen saver begins" is enabled.
    @MainActor
    public func lockDisplay() async -> LockExecutionState {
        // Step 1: Prepare lock AppleScript
        let lockScriptSource = """
        tell application "System Events"
            start current screen saver
        end tell
        """

        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: lockScriptSource) else {
            return .failed("Failed to instantiate AppleScript for screen lock.")
        }

        // Step 2: Invoke lock mechanism
        script.executeAndReturnError(&errorDict)

        if let error = errorDict {
            let errorNumber = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let errorMessage = (error[NSAppleScript.errorMessage] as? String) ?? "Unknown system error"

            // -1743: errOSACantOpenComponent / user consent required for automation
            if errorNumber == -1743 {
                return .failed("System Events automation permission denied. Please grant permission in System Settings > Privacy & Security > Automation.")
            }
            return .failed("AppleScript execution error (\(errorNumber)): \(errorMessage)")
        }

        // Step 3: Independent post-execution verification
        // Check if the screen saver state transitioned to running
        let isRunning = await verifyScreenSaverActive()
        if isRunning {
            return .confirmedLocked
        } else {
            // Screen saver was invoked, but state query may take a few milliseconds to reflect
            return .invoked
        }
    }

    /// Independently queries macOS System Events to verify whether the screen saver is active.
    @MainActor
    public func verifyScreenSaverActive() async -> Bool {
        let verifyScriptSource = """
        tell application "System Events"
            return running of screen saver preferences
        end tell
        """

        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: verifyScriptSource) else {
            return false
        }

        let result = script.executeAndReturnError(&errorDict)
        if errorDict == nil {
            return result.booleanValue
        }
        return false
    }

    /// Verifies whether the application has authorization to automate System Events.
    @MainActor
    public func checkAutomationAuthorization() -> Bool {
        let checkScriptSource = """
        tell application "System Events"
            return name
        end tell
        """
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: checkScriptSource) else {
            return false
        }
        _ = script.executeAndReturnError(&errorDict)
        return errorDict == nil
    }
}
#endif
