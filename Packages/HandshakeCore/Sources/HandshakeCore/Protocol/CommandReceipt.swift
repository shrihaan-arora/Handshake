import Foundation

/// Wire receipt confirmation transmitted from the iPhone to the host Mac
/// upon successfully receiving and cryptographically verifying a CommandAcknowledgment.
/// In two-stage command execution (e.g. system sleep), the Mac awaits this confirmation
/// before entering sleep to guarantee the client receives its acknowledgment without dropped packets.
public struct CommandReceipt: Codable, Sendable, Equatable, Identifiable {

    public var id: UUID { commandId }

    /// The unique identifier of the command whose acknowledgment is being confirmed.
    public let commandId: UUID

    /// Timestamp of receipt in epoch milliseconds.
    public let timestampMilliseconds: Int64

    /// The iPhone client's identity.
    public let clientIdentity: DeviceIdentity

    /// Digital signature over the receipt payload computed with the client's identity key.
    public let signatureHex: String

    public init(
        commandId: UUID,
        timestampMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        clientIdentity: DeviceIdentity,
        signatureHex: String = ""
    ) {
        self.commandId = commandId
        self.timestampMilliseconds = timestampMilliseconds
        self.clientIdentity = clientIdentity
        self.signatureHex = signatureHex
    }

    /// Associated data buffer for digital signature computation and verification.
    public var signablePayload: Data {
        var buffer = Data()
        withUnsafeBytes(of: commandId.uuid) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: timestampMilliseconds.bigEndian) { buffer.append(contentsOf: $0) }
        if let prefix = "RECEIPT-CONFIRMED".data(using: .utf8) { buffer.append(prefix) }
        if let clientKeyData = clientIdentity.publicKeyHex.data(using: .utf8) { buffer.append(clientKeyData) }
        return buffer
    }
}
