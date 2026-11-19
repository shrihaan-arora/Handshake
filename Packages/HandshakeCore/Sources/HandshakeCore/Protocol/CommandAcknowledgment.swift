import Foundation

/// Wire response transmitted from the Mac companion acknowledging command authentication and execution.
public struct CommandAcknowledgment: Codable, Sendable, Equatable, Identifiable {

    public enum ExecutionStatus: Codable, Sendable, Equatable {
        /// Packet received, authenticated, and scheduled for execution.
        case received
        /// The peer identity and signature were verified.
        case authenticated
        /// The trusted peer is permitted to invoke this command.
        case authorized
        /// The command was durably accepted. For Sleep Mac this does not claim the
        /// operating system has entered sleep.
        case accepted
        /// The host successfully submitted the request to the operating system.
        case sleepRequestIssued
        /// The host independently observed that the system entered sleep.
        case physicalSleepObserved
        /// Action successfully invoked on the host operating system.
        case executed
        /// Execution failed due to a system or permission error.
        case failed(String)
        /// Command rejected due to authentication, replay, or capability failure.
        case rejected(String)
    }

    public var id: UUID { commandId }

    /// The unique identifier of the command being acknowledged.
    public let commandId: UUID

    /// Execution and authorization status.
    public let status: ExecutionStatus

    /// Timestamp of execution in epoch milliseconds.
    public let timestampMilliseconds: Int64

    /// The host Mac's identity.
    public let hostIdentity: DeviceIdentity

    /// Digital signature over the acknowledgment fields computed with the Mac's identity key.
    public let signatureHex: String

    public init(
        commandId: UUID,
        status: ExecutionStatus,
        timestampMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        hostIdentity: DeviceIdentity,
        signatureHex: String = ""
    ) {
        self.commandId = commandId
        self.status = status
        self.timestampMilliseconds = timestampMilliseconds
        self.hostIdentity = hostIdentity
        self.signatureHex = signatureHex
    }

    /// Associated data buffer for digital signature verification.
    public var signablePayload: Data {
        var buffer = Data()
        withUnsafeBytes(of: commandId.uuid) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: timestampMilliseconds.bigEndian) { buffer.append(contentsOf: $0) }
        if let statusData = "\(status)".data(using: .utf8) { buffer.append(statusData) }
        if let hostKeyData = hostIdentity.publicKeyHex.data(using: .utf8) { buffer.append(hostKeyData) }
        return buffer
    }
}
