import Foundation
import CryptoKit

/// Wire message dispatched by an iPhone (client) upon establishing a TCP connection
/// to initiate a fresh, mutually authenticated, ephemeral cryptographic session.
public struct SessionInitiation: Codable, Sendable, Identifiable, Equatable {
    public let version: UInt8
    public let id: UUID // sessionId
    public let timestampMilliseconds: Int64
    public let clientIdentity: DeviceIdentity
    public let clientEphemeralPublicKeyHex: String
    public let signatureHex: String

    public init(
        version: UInt8 = 1,
        id: UUID = UUID(),
        timestampMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        clientIdentity: DeviceIdentity,
        clientEphemeralPublicKeyHex: String,
        signatureHex: String = ""
    ) {
        self.version = version
        self.id = id
        self.timestampMilliseconds = timestampMilliseconds
        self.clientIdentity = clientIdentity
        self.clientEphemeralPublicKeyHex = clientEphemeralPublicKeyHex
        self.signatureHex = signatureHex
    }

    /// Canonical signable payload binding the session parameters, client identity, and fresh ephemeral key.
    public var signablePayload: Data {
        var data = "HANDSHAKE-SESSION-INIT-v1".data(using: .utf8)!
        data.append(version)
        withUnsafeBytes(of: id.uuid) { data.append(contentsOf: $0) }
        var ts = timestampMilliseconds.bigEndian
        withUnsafeBytes(of: &ts) { data.append(contentsOf: $0) }
        data.append(clientIdentity.publicKeyHex.data(using: .utf8) ?? Data())
        data.append(clientEphemeralPublicKeyHex.data(using: .utf8) ?? Data())
        return data
    }
}

/// Wire message returned by the host Mac companion completing the mutual ephemeral handshake.
public struct SessionResponse: Codable, Sendable, Identifiable, Equatable {
    public let version: UInt8
    public let id: UUID // Matches SessionInitiation.id
    public let timestampMilliseconds: Int64
    public let hostIdentity: DeviceIdentity
    public let hostEphemeralPublicKeyHex: String
    public let signatureHex: String

    public init(
        version: UInt8 = 1,
        id: UUID,
        timestampMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        hostIdentity: DeviceIdentity,
        hostEphemeralPublicKeyHex: String,
        signatureHex: String = ""
    ) {
        self.version = version
        self.id = id
        self.timestampMilliseconds = timestampMilliseconds
        self.hostIdentity = hostIdentity
        self.hostEphemeralPublicKeyHex = hostEphemeralPublicKeyHex
        self.signatureHex = signatureHex
    }

    /// Canonical signable payload binding the session ID, host identity, and host ephemeral key.
    public var signablePayload: Data {
        var data = "HANDSHAKE-SESSION-RESP-v1".data(using: .utf8)!
        data.append(version)
        withUnsafeBytes(of: id.uuid) { data.append(contentsOf: $0) }
        var ts = timestampMilliseconds.bigEndian
        withUnsafeBytes(of: &ts) { data.append(contentsOf: $0) }
        data.append(hostIdentity.publicKeyHex.data(using: .utf8) ?? Data())
        data.append(hostEphemeralPublicKeyHex.data(using: .utf8) ?? Data())
        return data
    }
}

/// Active, verified cryptographic session state bound to a single connection lifetime.
/// Holds fresh directional symmetric keys, deterministic nonce salts, bounded expiration,
/// and an isolated, session-scoped sequence counter for anti-replay verification.
public struct EstablishedSession: Sendable {
    public let sessionId: UUID
    public let peer: DeviceIdentity
    public let clientToHostKey: SymmetricKey
    public let hostToClientKey: SymmetricKey
    public let clientToHostNonceSalt: Data // 4 bytes
    public let hostToClientNonceSalt: Data // 4 bytes
    public let establishedAt: Date
    public let expiresAt: Date
    public let incomingSequenceCounter: SequenceCounter

    public init(
        sessionId: UUID,
        peer: DeviceIdentity,
        clientToHostKey: SymmetricKey,
        hostToClientKey: SymmetricKey,
        clientToHostNonceSalt: Data,
        hostToClientNonceSalt: Data,
        establishedAt: Date = Date(),
        lifetimeSeconds: TimeInterval = 300.0, // 5 minute maximum per session
        incomingSequenceCounter: SequenceCounter = SequenceCounter()
    ) {
        self.sessionId = sessionId
        self.peer = peer
        self.clientToHostKey = clientToHostKey
        self.hostToClientKey = hostToClientKey
        self.clientToHostNonceSalt = clientToHostNonceSalt
        self.hostToClientNonceSalt = hostToClientNonceSalt
        self.establishedAt = establishedAt
        self.expiresAt = establishedAt.addingTimeInterval(lifetimeSeconds)
        self.incomingSequenceCounter = incomingSequenceCounter
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        date > expiresAt
    }
}

/// Cryptographic engine for deriving fresh session keys from an ephemeral key agreement.
public enum SessionKeyDerivation {

    public enum SessionError: Error, LocalizedError, Equatable {
        case sessionExpired
        case clockSkewExceeded
        case signatureVerificationFailed
        case untrustedPeer(String)
        case keyDerivationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .sessionExpired:
                return "The cryptographic session has expired and must be renegotiated."
            case .clockSkewExceeded:
                return "Handshake clock skew exceeds the acceptable 30-second window."
            case .signatureVerificationFailed:
                return "Digital signature verification over the session handshake failed."
            case .untrustedPeer(let details):
                return "Session peer is not trusted or recognized: \(details)"
            case .keyDerivationFailed(let msg):
                return "Session key derivation failed: \(msg)"
            }
        }
    }

    /// Derives directional keys and nonce salts from the ECDH shared secret, transcript, and master PSK.
    public static func deriveKeys(
        sharedSecret: SharedSecret,
        sessionId: UUID,
        transcript: Data,
        masterPSK: SymmetricKey?
    ) -> (clientToHostKey: SymmetricKey, hostToClientKey: SymmetricKey, clientNonceSalt: Data, hostNonceSalt: Data) {
        // Derive transcript salt bound to master PSK (if available)
        var saltInput = Data()
        if let psk = masterPSK {
            psk.withUnsafeBytes { saltInput.append(contentsOf: $0) }
        }
        withUnsafeBytes(of: sessionId.uuid) { saltInput.append(contentsOf: $0) }
        saltInput.append(transcript)
        let salt = SHA256.hash(data: saltInput)
        let saltData = Data(salt)

        let c2hInfo = "Handshake-Session-C2H-v1-\(sessionId.uuidString)".data(using: .utf8)!
        let h2cInfo = "Handshake-Session-H2C-v1-\(sessionId.uuidString)".data(using: .utf8)!
        let c2hSaltInfo = "Handshake-NonceSalt-C2H-v1-\(sessionId.uuidString)".data(using: .utf8)!
        let h2cSaltInfo = "Handshake-NonceSalt-H2C-v1-\(sessionId.uuidString)".data(using: .utf8)!

        let c2hKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: saltData,
            sharedInfo: c2hInfo,
            outputByteCount: 32
        )

        let h2cKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: saltData,
            sharedInfo: h2cInfo,
            outputByteCount: 32
        )

        let c2hNonceKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: saltData,
            sharedInfo: c2hSaltInfo,
            outputByteCount: 4
        )

        let h2cNonceKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: saltData,
            sharedInfo: h2cSaltInfo,
            outputByteCount: 4
        )

        let c2hNonceSalt = c2hNonceKey.withUnsafeBytes { Data($0) }
        let h2cNonceSalt = h2cNonceKey.withUnsafeBytes { Data($0) }

        return (c2hKey, h2cKey, c2hNonceSalt, h2cNonceSalt)
    }
}
