import Foundation
import CryptoKit

/// Ephemeral P-256 (secp256r1) Elliptic Curve Diffie-Hellman (ECDH) key exchange engine.
/// Provides forward secrecy for pairing and command sessions.
public struct EphemeralKeyExchange: Sendable {

    public enum ExchangeError: Error, LocalizedError, Equatable {
        case invalidPeerPublicKey
        case sharedSecretDerivationFailed
        case keyDerivationFailed

        public var errorDescription: String? {
            switch self {
            case .invalidPeerPublicKey:
                return "The peer's ephemeral public key was malformed or on an invalid curve."
            case .sharedSecretDerivationFailed:
                return "ECDH shared secret computation failed."
            case .keyDerivationFailed:
                return "HKDF key derivation failed."
            }
        }
    }

    private let privateKey: P256.KeyAgreement.PrivateKey

    public init() {
        self.privateKey = P256.KeyAgreement.PrivateKey()
    }

    /// Initializes with an explicit private key (useful for deterministic vector tests).
    public init(privateKey: P256.KeyAgreement.PrivateKey) {
        self.privateKey = privateKey
    }

    /// The ephemeral public key hex string (raw 64-byte point representation).
    public var publicKeyHex: String {
        privateKey.publicKey.rawRepresentation.hexString
    }

    /// Raw ephemeral public key data (64 bytes).
    public var publicKeyData: Data {
        privateKey.publicKey.rawRepresentation
    }

    // MARK: - Key Agreement

    /// Computes the ECDH shared secret with the peer's ephemeral public key.
    public func computeSharedSecret(peerEphemeralPublicKeyHex: String) throws -> SharedSecret {
        guard let peerKeyData = Data(hexString: peerEphemeralPublicKeyHex) else {
            throw ExchangeError.invalidPeerPublicKey
        }

        // Support both rawRepresentation (64 bytes) and x963Representation (65 bytes)
        let peerPublicKey: P256.KeyAgreement.PublicKey
        if let key = try? P256.KeyAgreement.PublicKey(rawRepresentation: peerKeyData) {
            peerPublicKey = key
        } else if let key = try? P256.KeyAgreement.PublicKey(x963Representation: peerKeyData) {
            peerPublicKey = key
        } else {
            throw ExchangeError.invalidPeerPublicKey
        }

        do {
            return try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        } catch {
            throw ExchangeError.sharedSecretDerivationFailed
        }
    }

    // MARK: - Key Derivation (HKDF-SHA256)

    /// Directional symmetric keys for authenticated bidirectional communication.
    public struct SessionKeys: Sendable {
        public let clientToHostKey: SymmetricKey
        public let hostToClientKey: SymmetricKey
    }

    /// Derives directional 256-bit AES-GCM session keys bound to a unique session UUID.
    public static func deriveSessionKeys(
        sharedSecret: SharedSecret,
        salt: Data,
        sessionId: UUID
    ) throws -> SessionKeys {
        let c2hInfo = "Handshake-v1-C2H-\(sessionId.uuidString)".data(using: .utf8)!
        let h2cInfo = "Handshake-v1-H2C-\(sessionId.uuidString)".data(using: .utf8)!

        let c2hKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: c2hInfo,
            outputByteCount: 32
        )

        let h2cKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: h2cInfo,
            outputByteCount: 32
        )

        return SessionKeys(clientToHostKey: c2hKey, hostToClientKey: h2cKey)
    }

    /// Computes the 6-digit Short Authentication String (SAS) independently on both devices.
    /// Binds the entire pairing transcript to prevent man-in-the-middle key substitution.
    public static func deriveSAS(
        sharedSecret: SharedSecret,
        salt: Data,
        transcript: Data
    ) -> String {
        var info = "Handshake-Pairing-SAS-v1".data(using: .utf8)!
        info.append(transcript)

        let derivedData = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        )

        // Extract first 4 bytes as big-endian UInt32 and reduce modulo 1,000,000
        let keyBytes = derivedData.withUnsafeBytes { Data($0) }
        guard keyBytes.count >= 4 else { return "000000" }

        let word = UInt32(keyBytes[0]) << 24 |
                   UInt32(keyBytes[1]) << 16 |
                   UInt32(keyBytes[2]) << 8  |
                   UInt32(keyBytes[3])

        let numericCode = word % 1_000_000
        return String(format: "%06d", numericCode)
    }
}
