import Foundation
import CryptoKit

/// End-to-end authenticated encryption and decryption channel for command messages.
/// Combines AES-256-GCM authenticated encryption with P-256 ECDSA digital signatures
/// and monotonic sequence-number replay protection.
public enum SecureChannel {

    public static let maximumPayloadSizeBytes: Int = 65_536 // 64 KB maximum envelope size

    public enum ChannelError: Error, LocalizedError, Equatable {
        case oversizedPayload(Int)
        case replayDetected(UInt64)
        case clockSkewExceeded(Int64)
        case signatureVerificationFailed
        case decryptionFailed
        case payloadExpired
        case encodingFailed
        case decodingFailed

        public var errorDescription: String? {
            switch self {
            case .oversizedPayload(let size):
                return "Payload size of \(size) bytes exceeds the maximum 64 KB limit."
            case .replayDetected(let seq):
                return "Replay attack detected: sequence number \(seq) rejected."
            case .clockSkewExceeded(let skew):
                return "Packet timestamp skew exceeds allowed threshold (\(skew) ms)."
            case .signatureVerificationFailed:
                return "Digital signature verification over the command envelope failed."
            case .decryptionFailed:
                return "AEAD decryption failed: ciphertext corrupted or authentication tag mismatch."
            case .payloadExpired:
                return "Command validity window expired."
            case .encodingFailed:
                return "Failed to serialize command message."
            case .decodingFailed:
                return "Failed to deserialize decrypted command payload."
            }
        }
    }

    // MARK: - Encryption / Sealing

    /// Encrypts and cryptographically signs a `CommandMessage` into a zero-trust `CommandEnvelope`.
    public static func seal(
        message: CommandMessage,
        sequenceNumber: UInt64,
        senderIdentity: CryptoIdentity,
        recipientPublicKeyHex: String,
        sessionKey: SymmetricKey,
        referenceTime: Date = Date()
    ) throws -> CommandEnvelope {
        let messageData = try JSONEncoder().encode(message)
        guard messageData.count <= maximumPayloadSizeBytes else {
            throw ChannelError.oversizedPayload(messageData.count)
        }

        let envelopeId = UUID()
        let timestampMs = Int64(referenceTime.timeIntervalSince1970 * 1000)

        // 12-byte cryptographically secure random nonce
        let nonce = AES.GCM.Nonce()
        let nonceData = Data(nonce)

        // Build envelope with placeholder tag and signature to construct canonical AAD
        let envelopePlaceholder = CommandEnvelope(
            version: 1,
            id: envelopeId,
            senderPublicKeyHex: senderIdentity.identity.publicKeyHex,
            recipientPublicKeyHex: recipientPublicKeyHex,
            sequenceNumber: sequenceNumber,
            timestampMilliseconds: timestampMs,
            nonceHex: nonceData.hexString,
            ciphertextHex: "",
            authTagHex: "",
            signatureHex: ""
        )
        let aad = envelopePlaceholder.associatedDataPayload

        // AEAD encryption
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(
                messageData,
                using: sessionKey,
                nonce: nonce,
                authenticating: aad
            )
        } catch {
            throw ChannelError.encodingFailed
        }

        let ciphertextData = sealedBox.ciphertext
        let authTagData = sealedBox.tag

        // Digital signature over SHA-256 of (AAD || Ciphertext || AuthTag)
        var signableBuffer = aad
        signableBuffer.append(ciphertextData)
        signableBuffer.append(authTagData)

        let signature = try senderIdentity.sign(data: signableBuffer)

        return CommandEnvelope(
            version: 1,
            id: envelopeId,
            senderPublicKeyHex: senderIdentity.identity.publicKeyHex,
            recipientPublicKeyHex: recipientPublicKeyHex,
            sequenceNumber: sequenceNumber,
            timestampMilliseconds: timestampMs,
            nonceHex: nonceData.hexString,
            ciphertextHex: ciphertextData.hexString,
            authTagHex: authTagData.hexString,
            signatureHex: signature.hexString
        )
    }

    // MARK: - Decryption / Opening

    /// Validates, authenticates, and decrypts an incoming `CommandEnvelope`.
    /// Rejects replayed, expired, modified, or untrusted envelopes.
    public static func open(
        envelope: CommandEnvelope,
        sessionKey: SymmetricKey,
        trustedSenderPublicKeyHex: String,
        sequenceCounter: SequenceCounter,
        referenceTime: Date = Date()
    ) async throws -> CommandMessage {
        // 1. Check wire size bound
        guard let ciphertextData = Data(hexString: envelope.ciphertextHex) else {
            throw ChannelError.decryptionFailed
        }
        guard ciphertextData.count <= maximumPayloadSizeBytes else {
            throw ChannelError.oversizedPayload(ciphertextData.count)
        }

        // 2. Validate timestamp freshness against clock skew
        guard HandshakeTime.isTimestampValid(envelope.timestampMilliseconds, referenceTime: referenceTime) else {
            throw ChannelError.clockSkewExceeded(envelope.timestampMilliseconds)
        }

        // 3. Pre-flight check monotonic sequence counter without mutating state
        let isSeqFresh = await sequenceCounter.checkIncoming(envelope.sequenceNumber)
        guard isSeqFresh else {
            throw ChannelError.replayDetected(envelope.sequenceNumber)
        }

        // 4. Verify sender identity matches expected peer
        guard envelope.senderPublicKeyHex.lowercased() == trustedSenderPublicKeyHex.lowercased() else {
            throw ChannelError.signatureVerificationFailed
        }

        // 5. Verify digital signature over (AAD || Ciphertext || AuthTag)
        guard let authTagData = Data(hexString: envelope.authTagHex),
              let signatureData = Data(hexString: envelope.signatureHex),
              let nonceData = Data(hexString: envelope.nonceHex) else {
            throw ChannelError.decryptionFailed
        }

        let aad = envelope.associatedDataPayload
        var signableBuffer = aad
        signableBuffer.append(ciphertextData)
        signableBuffer.append(authTagData)

        let isSigValid = CryptoIdentity.verify(
            signatureRaw: signatureData,
            for: signableBuffer,
            publicKeyHex: envelope.senderPublicKeyHex
        )
        guard isSigValid else {
            throw ChannelError.signatureVerificationFailed
        }

        // 6. AEAD Decryption
        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: nonceData)
        } catch {
            throw ChannelError.decryptionFailed
        }

        guard let sealedBox = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertextData, tag: authTagData) else {
            throw ChannelError.decryptionFailed
        }

        let decryptedData: Data
        do {
            decryptedData = try AES.GCM.open(sealedBox, using: sessionKey, authenticating: aad)
        } catch {
            throw ChannelError.decryptionFailed
        }

        // 7. Deserialize CommandMessage
        guard let message = try? JSONDecoder().decode(CommandMessage.self, from: decryptedData) else {
            throw ChannelError.decodingFailed
        }

        // 8. Verify command message validity horizon
        guard !message.isExpired(at: referenceTime) else {
            throw ChannelError.payloadExpired
        }

        // 9. Commit sequence number into replay filter only after cryptographic authentication passes
        let isSeqCommitted = await sequenceCounter.validateAndAcceptIncoming(envelope.sequenceNumber)
        guard isSeqCommitted else {
            throw ChannelError.replayDetected(envelope.sequenceNumber)
        }

        return message
    }
}
