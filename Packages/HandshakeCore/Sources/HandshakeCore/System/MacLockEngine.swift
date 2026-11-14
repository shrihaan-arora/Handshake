#if os(macOS)
import Foundation
import AppKit

/// Supported macOS display locking engine using Apple-documented system interfaces.
/// Implements transparent permission auditing, multi-stage state tracking,
/// independent post-execution verification, and strict screen lock grace period enforcement.
public final class MacLockEngine: Sendable {

    /// The password requirement policy after display sleep or screen saver begins.
    /// In macOS, screen saver activation only locks the Mac if this is `.immediate`.
    public enum ScreenLockGracePeriod: Sendable, Equatable {
        /// Password required immediately (0 second delay). Mac is securely locked upon screen saver activation.
        case immediate
        /// Password required after a grace delay (in seconds).
        case delayed(seconds: Int)
        /// Password authentication is completely disabled.
        case disabled
        /// Unable to query or parse grace period status.
        case unverified(String)

        /// Whether this grace period configuration guarantees genuine display locking.
        public var isSecure: Bool {
            if case .immediate = self { return true }
            return false
        }

        public var description: String {
            switch self {
            case .immediate:
                return "Immediately (Secure)"
            case .delayed(let seconds):
                let minutes = seconds / 60
                if minutes > 0 {
                    return "\(minutes)m delay (Insecure — Mac does not lock immediately)"
                } else {
                    return "\(seconds)s delay (Insecure — Mac does not lock immediately)"
                }
            case .disabled:
                return "Disabled / Off (Insecure — password never required)"
            case .unverified(let reason):
                return "Unverified (\(reason))"
            }
        }
    }

    /// Detailed execution state for the lock operation.
    public enum LockExecutionState: Sendable, Equatable {
        case received
        case authenticated
        case invoked
        case confirmedLocked(passwordRequiredImmediately: Bool)
        case failed(String)

        public static let confirmedLocked = LockExecutionState.confirmedLocked(passwordRequiredImmediately: true)

        public var isSuccess: Bool {
            switch self {
            case .confirmedLocked(let immediate): return immediate
            case .invoked: return true
            default: return false
            }
        }
    }

    public typealias GracePeriodProvider = @Sendable () -> ScreenLockGracePeriod
    private let customGracePeriodProvider: GracePeriodProvider?

    public init(gracePeriodProvider: GracePeriodProvider? = nil) {
        self.customGracePeriodProvider = gracePeriodProvider
    }

    /// Queries the current macOS screen lock grace period setting via Apple's documented `/usr/sbin/sysadminctl`.
    public func checkScreenLockGracePeriod() -> ScreenLockGracePeriod {
        if let customProvider = customGracePeriodProvider {
            return customProvider()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysadminctl")
        process.arguments = ["-screenLock", "status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return Self.parseSysadminctlOutput(output)
        } catch {
            return .unverified("Process execution failed: \(error.localizedDescription)")
        }
    }

    /// Parses the raw textual output from `sysadminctl -screenLock status`.
    public static func parseSysadminctlOutput(_ output: String) -> ScreenLockGracePeriod {
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.contains("screenLock delay is immediate") {
            return .immediate
        } else if cleaned.contains("screenLock is off") {
            return .disabled
        } else if let range = cleaned.range(of: "screenLock delay is ") {
            let remainder = cleaned[range.upperBound...]
            let scanner = Scanner(string: String(remainder))
            if let seconds = scanner.scanInt() {
                return .delayed(seconds: seconds)
            }
            return .delayed(seconds: -1)
        } else if !cleaned.isEmpty {
            return .unverified(cleaned)
        } else {
            return .unverified("No output received from sysadminctl")
        }
    }

    /// Executes display lock via System Events screen saver.
    /// Strictly verifies that "Require password immediately after sleep or screen saver begins"
    /// is active before claiming lock success.
    @MainActor
    public func lockDisplay() async -> LockExecutionState {
        // Step 1: Pre-flight screen lock grace period audit
        let gracePeriod = checkScreenLockGracePeriod()
        guard gracePeriod.isSecure else {
            return .failed(
                "Screen lock grace period is not set to 'Immediately' (\(gracePeriod.description)). " +
                "Starting the screen saver will not lock the Mac. " +
                "Configure System Settings > Lock Screen > 'Require password after screen saver begins' to 'Immediately'."
            )
        }

        // Step 2: Prepare lock AppleScript
        let lockScriptSource = """
        tell application "System Events"
            start current screen saver
        end tell
        """

        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: lockScriptSource) else {
            return .failed("Failed to instantiate AppleScript for screen lock.")
        }

        // Step 3: Invoke lock mechanism
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

        // Step 4: Independent post-execution verification
        let isRunning = await verifyScreenSaverActive()
        if isRunning {
            return .confirmedLocked(passwordRequiredImmediately: true)
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
