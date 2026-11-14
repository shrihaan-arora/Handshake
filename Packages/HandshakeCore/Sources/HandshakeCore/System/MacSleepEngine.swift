#if os(macOS)
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Supported macOS system sleep engine using Apple's documented IOKit power management API.
/// Coordinates the orderly sleep execution pipeline: validate -> prepare -> ack -> flush -> sleep.
public final class MacSleepEngine: Sendable {

    /// Detailed execution state for the sleep operation.
    public enum SleepExecutionState: Sendable, Equatable {
        case received
        case authenticated
        case prepared
        case acknowledgmentFlushed
        case sleepInitiated
        case sleepNotSupported
        case failed(String)

        public var isSuccess: Bool {
            switch self {
            case .sleepInitiated, .acknowledgmentFlushed: return true
            default: return false
            }
        }
    }

    public init() {}

    /// Checks if system sleep is supported by the Mac hardware and power management subsystem.
    public func isSleepSupported() -> Bool {
        return IOPMSleepEnabled() != 0
    }

    /// Triggers the system sleep operation using Apple's documented IOKit IOPMSleepSystem API.
    /// This method must strictly be invoked AFTER the signed acknowledgment has been transmitted
    /// and the network buffers have been allowed to flush.
    public func triggerSleep() -> SleepExecutionState {
        guard isSleepSupported() else {
            return .sleepNotSupported
        }

        // 1. Primary mechanism: IOPMSleepSystem via Root Power Domain
        let masterPort = mach_port_t(MACH_PORT_NULL)
        let rootDomain = IOPMFindPowerManagement(masterPort)

        if rootDomain != 0 {
            defer {
                IOServiceClose(rootDomain)
            }
            let ioReturn = IOPMSleepSystem(rootDomain)
            if ioReturn == kIOReturnSuccess {
                return .sleepInitiated
            }
        }

        // 2. Fallback mechanism: System Events script
        return triggerSystemEventsSleep()
    }

    /// Fallback sleep invocation via AppleScript System Events
    private func triggerSystemEventsSleep() -> SleepExecutionState {
        let sleepScript = """
        tell application "System Events"
            sleep
        end tell
        """

        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: sleepScript) else {
            return .failed("Failed to instantiate AppleScript for system sleep.")
        }

        script.executeAndReturnError(&errorDict)
        if let error = errorDict {
            let errorNumber = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let errorMessage = (error[NSAppleScript.errorMessage] as? String) ?? "Unknown system error"
            return .failed("System Events sleep error (\(errorNumber)): \(errorMessage)")
        }

        return .sleepInitiated
    }
}
#endif
