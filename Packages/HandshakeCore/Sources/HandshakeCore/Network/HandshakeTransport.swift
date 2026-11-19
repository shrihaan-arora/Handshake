import Foundation
import Network

/// Unified framed transport abstraction allowing the identical cryptographic protocol
/// (ephemeral P-256 ECDH, directional AES-256-GCM, sequence validation, signed acknowledgments)
/// to execute interchangeably over local TCP or Bluetooth Low Energy.
public protocol HandshakeFramedTransport: Sendable {
    /// Active transport type.
    var transportType: TransportType { get }

    /// Transmits an unencrypted or encrypted protocol frame.
    func send(frameData: Data) async throws

    /// Awaits and returns a complete incoming frame with optional bounded timeout.
    func receive(timeoutSeconds: TimeInterval?) async throws -> Data

    /// Closes the underlying transport channel.
    func close() async
}

// MARK: - TCP Framed Transport

/// Implementation of `HandshakeFramedTransport` backed by an active `NWConnection`.
public final class TCPFramedTransport: HandshakeFramedTransport, @unchecked Sendable {
    public let transportType: TransportType = .localWiFi
    private let connection: NWConnection

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public func send(frameData: Data) async throws {
        try await NetworkFraming.send(data: frameData, over: connection)
    }

    public func receive(timeoutSeconds: TimeInterval? = nil) async throws -> Data {
        try await NetworkFraming.receive(from: connection, timeoutSeconds: timeoutSeconds)
    }

    public func close() async {
        connection.cancel()
    }
}
