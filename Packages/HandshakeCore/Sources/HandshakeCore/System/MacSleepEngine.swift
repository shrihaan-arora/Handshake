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

    public typealias SleepTriggerAction = @Sendable () -> SleepExecutionState
    private let customSleepTrigger: SleepTriggerAction?

    public init(customSleepTrigger: SleepTriggerAction? = nil) {
        self.customSleepTrigger = customSleepTrigger
    }

    /// Checks if system sleep is supported by the Mac hardware and power management subsystem.
    public func isSleepSupported() -> Bool {
        if customSleepTrigger != nil { return true }
        return IOPMSleepEnabled() != 0
    }

    /// Triggers the system sleep operation using Apple's documented IOKit IOPMSleepSystem API.
    /// This method must strictly be invoked AFTER the signed acknowledgment has been transmitted
    /// and the network buffers have been allowed to flush.
    public func triggerSleep() -> SleepExecutionState {
        if let customTrigger = customSleepTrigger {
            return customTrigger()
        }

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
            } else {
                return .failed("IOKit IOPMSleepSystem returned error code: \(ioReturn)")
            }
        }

        return .failed("Unable to locate IOKit Root Power Domain.")
    }
}
#endif
