import Foundation

/// Wire-level security envelope encapsulating encrypted command messages.
/// Designed for zero-trust transport across Wi-Fi or Bluetooth Low Energy.
public struct CommandEnvelope: Codable, Sendable, Identifiable, Equatable {
    /// Protocol schema version.
    public let version: UInt8

    /// Unique identifier for tracing and deduplication.
    public let id: UUID

    /// Hex-encoded sender public key identifier.
    public let senderPublicKeyHex: String

    /// Hex-encoded recipient public key identifier.
    public let recipientPublicKeyHex: String

    /// Monotonically increasing sequence number per peer session.
    public let sequenceNumber: UInt64

    /// UTC timestamp in epoch milliseconds.
    public let timestampMilliseconds: Int64

    /// 12-byte initialization vector / nonce (hex-encoded).
    public let nonceHex: String

    /// AEAD ciphertext payload (hex-encoded).
    public let ciphertextHex: String

    /// 16-byte Poly1305 / GCM authentication tag (hex-encoded).
    public let authTagHex: String

    /// Ed25519 digital signature over the authenticated header and ciphertext (hex-encoded).
    public let signatureHex: String

    public init(
        version: UInt8 = 1,
        id: UUID = UUID(),
        senderPublicKeyHex: String,
        recipientPublicKeyHex: String,
        sequenceNumber: UInt64,
        timestampMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        nonceHex: String,
        ciphertextHex: String,
        authTagHex: String,
        signatureHex: String
    ) {
        self.version = version
        self.id = id
        self.senderPublicKeyHex = senderPublicKeyHex
        self.recipientPublicKeyHex = recipientPublicKeyHex
        self.sequenceNumber = sequenceNumber
        self.timestampMilliseconds = timestampMilliseconds
        self.nonceHex = nonceHex
        self.ciphertextHex = ciphertextHex
        self.authTagHex = authTagHex
        self.signatureHex = signatureHex
    }

    /// Associated data byte buffer used to bind envelope metadata to the AEAD authentication tag.
    /// Uses length-prefixing for variable-length strings to eliminate canonicalization delimiter collisions.
    public var associatedDataPayload: Data {
        var buffer = Data()
        buffer.append(version)
        withUnsafeBytes(of: id.uuid) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: sequenceNumber.bigEndian) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: timestampMilliseconds.bigEndian) { buffer.append(contentsOf: $0) }

        let senderData = senderPublicKeyHex.data(using: .utf8) ?? Data()
        var senderLen = UInt16(senderData.count).bigEndian
        withUnsafeBytes(of: &senderLen) { buffer.append(contentsOf: $0) }
        buffer.append(senderData)

        let recipientData = recipientPublicKeyHex.data(using: .utf8) ?? Data()
        var recipientLen = UInt16(recipientData.count).bigEndian
        withUnsafeBytes(of: &recipientLen) { buffer.append(contentsOf: $0) }
        buffer.append(recipientData)

        return buffer
    }
}

