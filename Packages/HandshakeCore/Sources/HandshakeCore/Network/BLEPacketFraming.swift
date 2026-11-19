import Foundation

/// High-reliability packet chunking, reassembly, and length-prefixed framing for
/// CoreBluetooth GATT characteristic transmissions.
///
/// Designed to transmit arbitrary payloads up to 64 KB over Bluetooth Low Energy
/// by chunking frames according to dynamic ATT MTU limits with sequence ordering,
/// length verification, and flow control.
///
/// Adapted with attribution from BLESwift (Apache-2.0 license):
/// Copyright (c) Kyle Browning and BLESwift contributors.
public enum BLEPacketFraming {

    /// Maximum permissible payload size for a single assembled message frame (64 KB).
    public static let maximumPayloadLength: Int = 65_536

    /// Conservative fallback chunk size when dynamic MTU is unavailable.
    public static let defaultChunkSize: Int = 180

    public enum FramingError: Error, LocalizedError, Equatable {
        case payloadTooLarge(Int)
        case truncatedHeader
        case outOfOrderChunk(expected: UInt8, received: UInt8)
        case chunkExceedsDeclaredLength(declared: Int, received: Int)
        case lengthMismatch(expected: Int, actual: Int)
        case timeout
        case invalidChunkHeader

        public var errorDescription: String? {
            switch self {
            case .payloadTooLarge(let size):
                return "Payload length of \(size) bytes exceeds maximum allowed 64 KB BLE boundary."
            case .truncatedHeader:
                return "Received truncated BLE chunk header."
            case .outOfOrderChunk(let exp, let rec):
                return "BLE chunk sequence mismatch: expected \(exp), received \(rec)."
            case .chunkExceedsDeclaredLength(let decl, let rec):
                return "Accumulated BLE chunk data (\(rec) bytes) exceeds declared payload length (\(decl) bytes)."
            case .lengthMismatch(let exp, let act):
                return "BLE frame assembly completed with length mismatch: expected \(exp) bytes, got \(act) bytes."
            case .timeout:
                return "BLE frame reassembly timed out."
            case .invalidChunkHeader:
                return "Invalid or corrupt BLE chunk header received."
            }
        }
    }

    // MARK: - Chunking (Sender)

    /// Chunks a framed payload into an array of MTU-bounded packets.
    ///
    /// Packet Wire Format:
    /// - Start Chunk:
    ///   `[Flags: 1 byte (0x80 | 0x40 if end | seq: 0..63)] [Length: 4 bytes big-endian] [Payload Slice]`
    /// - Continuation Chunk:
    ///   `[Flags: 1 byte (0x40 if end | seq: 0..63)] [Payload Slice]`
    public static func chunk(frame: Data, maxChunkSize: Int = defaultChunkSize) throws -> [Data] {
        guard frame.count <= maximumPayloadLength else {
            throw FramingError.payloadTooLarge(frame.count)
        }

        let safeMaxChunk = max(20, maxChunkSize)
        var chunks: [Data] = []
        let totalCount = frame.count

        // Handle empty payload case
        if totalCount == 0 {
            var chunk = Data(capacity: 5)
            let flags: UInt8 = 0xC0 // Start + End, seq 0
            chunk.append(flags)
            var len = UInt32(0).bigEndian
            withUnsafeBytes(of: &len) { chunk.append(contentsOf: $0) }
            return [chunk]
        }

        var offset = 0
        var seq: UInt8 = 0

        while offset < totalCount {
            let isStart = (offset == 0)
            let headerSize = isStart ? 5 : 1
            let maxPayloadSlice = safeMaxChunk - headerSize
            guard maxPayloadSlice > 0 else {
                throw FramingError.invalidChunkHeader
            }

            let sliceSize = min(maxPayloadSlice, totalCount - offset)
            let isEnd = (offset + sliceSize == totalCount)

            var flags: UInt8 = (seq & 0x3F)
            if isStart { flags |= 0x80 }
            if isEnd { flags |= 0x40 }

            var chunk = Data(capacity: headerSize + sliceSize)
            chunk.append(flags)

            if isStart {
                var len = UInt32(totalCount).bigEndian
                withUnsafeBytes(of: &len) { chunk.append(contentsOf: $0) }
            }

            chunk.append(frame.subdata(in: offset..<(offset + sliceSize)))
            chunks.append(chunk)

            offset += sliceSize
            seq = (seq + 1) & 0x3F
        }

        return chunks
    }

    // MARK: - Reassembly (Receiver)

    /// State-managed, thread-safe reassembler for incoming BLE GATT chunks.
    public final class Reassembler: @unchecked Sendable {
        private var buffer = Data()
        private var declaredLength: Int? = nil
        private var expectedSeq: UInt8 = 0
        private let lock = NSLock()

        public init() {}

        /// Resets the current reassembly state and releases buffered memory.
        public func reset() {
            lock.lock()
            defer { lock.unlock() }
            resetUnlocked()
        }

        /// Ingests a raw BLE GATT chunk. Returns complete reassembled Data when the final
        /// chunk arrives and matches declared length, or nil if more chunks are awaited.
        public func processChunk(_ chunk: Data) throws -> Data? {
            lock.lock()
            defer { lock.unlock() }

            guard !chunk.isEmpty else { return nil }
            let flags = chunk[0]
            let isStart = (flags & 0x80) != 0
            let isEnd = (flags & 0x40) != 0
            let seq = flags & 0x3F

            if isStart {
                guard chunk.count >= 5 else {
                    resetUnlocked()
                    throw FramingError.truncatedHeader
                }
                let len = chunk.withUnsafeBytes { ptr in
                    ptr.loadUnaligned(fromByteOffset: 1, as: UInt32.self).bigEndian
                }
                let intLen = Int(len)
                guard intLen <= maximumPayloadLength else {
                    resetUnlocked()
                    throw FramingError.payloadTooLarge(intLen)
                }

                declaredLength = intLen
                buffer.removeAll(keepingCapacity: true)
                buffer.reserveCapacity(intLen)
                expectedSeq = (seq + 1) & 0x3F
                buffer.append(chunk.subdata(in: 5..<chunk.count))
            } else {
                guard let declared = declaredLength else {
                    // Orphan continuation chunk without a preceding start chunk
                    return nil
                }
                guard seq == expectedSeq else {
                    let expected = expectedSeq
                    resetUnlocked()
                    throw FramingError.outOfOrderChunk(expected: expected, received: seq)
                }
                expectedSeq = (expectedSeq + 1) & 0x3F
                buffer.append(chunk.subdata(in: 1..<chunk.count))

                if buffer.count > declared {
                    let rec = buffer.count
                    resetUnlocked()
                    throw FramingError.chunkExceedsDeclaredLength(declared: declared, received: rec)
                }
            }

            if isEnd {
                guard let declared = declaredLength else {
                    resetUnlocked()
                    return nil
                }
                guard buffer.count == declared else {
                    let act = buffer.count
                    resetUnlocked()
                    throw FramingError.lengthMismatch(expected: declared, actual: act)
                }
                let completeFrame = buffer
                resetUnlocked()
                return completeFrame
            }

            return nil
        }

        private func resetUnlocked() {
            buffer.removeAll(keepingCapacity: false)
            declaredLength = nil
            expectedSeq = 0
        }
    }
}
