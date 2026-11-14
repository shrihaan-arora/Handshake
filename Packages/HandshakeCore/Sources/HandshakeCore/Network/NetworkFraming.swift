import Foundation
import Network

/// Standardized wire framing utility for peer-to-peer TCP communication over Network.framework.
/// Uses 4-byte big-endian length prefixing with a strict 64 KB packet boundary.
public enum NetworkFraming {

    public static let maximumFrameSizeBytes: UInt32 = 65_536 // 64 KB limit

    public enum FramingError: Error, LocalizedError, Equatable {
        case frameTooLarge(UInt32)
        case truncatedHeader
        case connectionClosed
        case transmissionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .frameTooLarge(let size):
                return "Incoming frame size \(size) bytes exceeds maximum allowed 64 KB boundary."
            case .truncatedHeader:
                return "Truncated frame header received."
            case .connectionClosed:
                return "The network connection was closed unexpectedly."
            case .transmissionFailed(let msg):
                return "Failed to transmit frame: \(msg)"
            }
        }
    }

    /// Encapsulates raw payload data with a 4-byte big-endian length header.
    public static func frame(data: Data) throws -> Data {
        guard data.count <= Int(maximumFrameSizeBytes) else {
            throw FramingError.frameTooLarge(UInt32(data.count))
        }

        var header = UInt32(data.count).bigEndian
        var framed = Data()
        withUnsafeBytes(of: &header) { framed.append(contentsOf: $0) }
        framed.append(data)
        return framed
    }

    /// Sends a length-prefixed frame asynchronously over an NWConnection.
    public static func send(
        data: Data,
        over connection: NWConnection
    ) async throws {
        let framedData = try frame(data: data)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: framedData,
                completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: FramingError.transmissionFailed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    /// Receives a complete length-prefixed frame asynchronously from an NWConnection.
    public static func receive(
        from connection: NWConnection
    ) async throws -> Data {
        // 1. Read 4-byte header
        let headerData = try await receiveExactBytes(count: 4, from: connection)
        guard headerData.count == 4 else {
            throw FramingError.truncatedHeader
        }

        let length = headerData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length <= maximumFrameSizeBytes else {
            throw FramingError.frameTooLarge(length)
        }

        guard length > 0 else { return Data() }

        // 2. Read full frame payload
        return try await receiveExactBytes(count: Int(length), from: connection)
    }

    private static func receiveExactBytes(
        count: Int,
        from connection: NWConnection
    ) async throws -> Data {
        var accumulated = Data()

        while accumulated.count < count {
            let remaining = count - accumulated.count
            let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { content, _, isComplete, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let data = content, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: FramingError.connectionClosed)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            guard !chunk.isEmpty else {
                throw FramingError.connectionClosed
            }
            accumulated.append(chunk)
        }

        return accumulated
    }
}
