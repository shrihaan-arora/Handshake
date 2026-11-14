import Foundation
import CryptoKit
import Security

/// Cryptographic signing and identity management engine.
/// Standardizes on NIST P-256 (secp256r1) ECDSA.
/// Evaluates and supports Apple Secure Enclave on physical devices,
/// with clearly isolated and honestly disclosed Keychain-backed software fallback on Simulators.
public final class CryptoIdentity: Sendable {

    public enum IdentityError: Error, LocalizedError, Equatable {
        case keyGenerationFailed(String)
        case keyNotFound
        case invalidKeyData
        case signingFailed(String)
        case signatureVerificationFailed

        public var errorDescription: String? {
            switch self {
            case .keyGenerationFailed(let msg): return "Failed to generate identity key: \(msg)"
            case .keyNotFound: return "Long-term identity key was not found."
            case .invalidKeyData: return "Invalid public or private key data representation."
            case .signingFailed(let msg): return "Failed to sign payload: \(msg)"
            case .signatureVerificationFailed: return "Digital signature verification failed."
            }
        }
    }

    /// Whether the device hardware features an operational Apple Secure Enclave.
    public static var isSecureEnclaveSupported: Bool {
        SecureEnclave.isAvailable
    }

    /// The local device's public identity descriptor.
    public let identity: DeviceIdentity

    /// Whether this specific identity's private key is hardware-isolated in the Secure Enclave.
    public let isHardwareBacked: Bool

    private let softwarePrivateKey: P256.Signing.PrivateKey?
    private let secureEnclaveKeyData: Data?

    // MARK: - Initializers

    /// Private internal initializer for software-backed key.
    private init(
        identity: DeviceIdentity,
        softwarePrivateKey: P256.Signing.PrivateKey
    ) {
        self.identity = identity
        self.softwarePrivateKey = softwarePrivateKey
        self.secureEnclaveKeyData = nil
        self.isHardwareBacked = false
    }

    /// Private internal initializer for Secure Enclave key.
    private init(
        identity: DeviceIdentity,
        secureEnclaveKeyData: Data
    ) {
        self.identity = identity
        self.softwarePrivateKey = nil
        self.secureEnclaveKeyData = secureEnclaveKeyData
        self.isHardwareBacked = true
    }

    // MARK: - Factory & Persistence

    /// Loads an existing long-term identity from Keychain or creates a new one.
    /// Prefers Secure Enclave on physical hardware; falls back to software Keychain on Simulators.
    public static func loadOrCreate(
        label: String = "com.handshake.identity.default",
        displayName: String,
        deviceType: DeviceType,
        modelIdentifier: String = "AppleDevice",
        systemVersion: String = "17.0",
        keychain: KeychainManager = .shared
    ) throws -> CryptoIdentity {
        let privateKeyAccount = "\(label).privateKey"
        let metadataAccount = "\(label).metadata"

        // 1. Attempt to load existing identity metadata
        if let metadataData = try? keychain.retrieve(forAccount: metadataAccount),
           let savedIdentity = try? JSONDecoder().decode(DeviceIdentity.self, from: metadataData) {

            // Attempt to load private key
            if let keyBytes = try? keychain.retrieve(forAccount: privateKeyAccount) {
                // Check if it was stored as SecureEnclave representation
                if let seKey = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: keyBytes) {
                    return CryptoIdentity(identity: savedIdentity, secureEnclaveKeyData: seKey.dataRepresentation)
                }

                // Or software-backed raw representation
                if let softKey = try? P256.Signing.PrivateKey(rawRepresentation: keyBytes) {
                    return CryptoIdentity(identity: savedIdentity, softwarePrivateKey: softKey)
                }
            }
        }

        // 2. Generate new identity
        return try createNew(
            label: label,
            displayName: displayName,
            deviceType: deviceType,
            modelIdentifier: modelIdentifier,
            systemVersion: systemVersion,
            keychain: keychain
        )
    }

    /// Creates a brand new identity, storing private keys and metadata in Keychain.
    public static func createNew(
        label: String = "com.handshake.identity.default",
        displayName: String,
        deviceType: DeviceType,
        modelIdentifier: String,
        systemVersion: String,
        preferSecureEnclave: Bool = true,
        keychain: KeychainManager = .shared
    ) throws -> CryptoIdentity {
        let privateKeyAccount = "\(label).privateKey"
        let metadataAccount = "\(label).metadata"

        #if !targetEnvironment(simulator)
        if preferSecureEnclave && SecureEnclave.isAvailable {
            do {
                let accessControl = SecAccessControlCreateWithFlags(
                    kCFAllocatorDefault,
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    .privateKeyUsage,
                    nil
                )
                let seKey = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl ?? SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, [], nil)!)
                let publicKeyHex = seKey.publicKey.rawRepresentation.hexString

                let identity = DeviceIdentity(
                    id: UUID(),
                    publicKeyHex: publicKeyHex,
                    displayName: displayName,
                    deviceType: deviceType,
                    modelIdentifier: modelIdentifier,
                    systemVersion: systemVersion,
                    createdAt: Date()
                )

                // Save to Keychain
                try keychain.save(data: seKey.dataRepresentation, forAccount: privateKeyAccount)
                let metadataData = try JSONEncoder().encode(identity)
                try keychain.save(data: metadataData, forAccount: metadataAccount)

                return CryptoIdentity(identity: identity, secureEnclaveKeyData: seKey.dataRepresentation)
            } catch {
                // Secure Enclave generation failed, proceed to software fallback
            }
        }
        #endif

        // Software-backed fallback (Standard on Simulators and environments without Enclave)
        let softwareKey = P256.Signing.PrivateKey()
        let publicKeyHex = softwareKey.publicKey.rawRepresentation.hexString

        let identity = DeviceIdentity(
            id: UUID(),
            publicKeyHex: publicKeyHex,
            displayName: displayName,
            deviceType: deviceType,
            modelIdentifier: modelIdentifier,
            systemVersion: systemVersion,
            createdAt: Date()
        )

        // Save private key raw bytes and metadata
        try keychain.save(data: softwareKey.rawRepresentation, forAccount: privateKeyAccount)
        let metadataData = try JSONEncoder().encode(identity)
        try keychain.save(data: metadataData, forAccount: metadataAccount)

        return CryptoIdentity(identity: identity, softwarePrivateKey: softwareKey)
    }

    // MARK: - Digital Signatures (ECDSA)

    /// Signs arbitrary binary data using the device's P-256 private key.
    /// Returns the raw 64-byte (r || s) ECDSA signature.
    public func sign(data: Data) throws -> Data {
        if let softwareKey = softwarePrivateKey {
            do {
                let signature = try softwareKey.signature(for: data)
                return signature.rawRepresentation
            } catch {
                throw IdentityError.signingFailed(error.localizedDescription)
            }
        }

        #if !targetEnvironment(simulator)
        if let seKeyData = secureEnclaveKeyData {
            do {
                let seKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: seKeyData)
                let signature = try seKey.signature(for: data)
                return signature.rawRepresentation
            } catch {
                throw IdentityError.signingFailed(error.localizedDescription)
            }
        }
        #endif

        throw IdentityError.keyNotFound
    }

    /// Verifies a 64-byte raw P-256 ECDSA signature against the provided public key hex string and payload data.
    public static func verify(
        signatureRaw: Data,
        for data: Data,
        publicKeyHex: String
    ) -> Bool {
        guard let pubKeyData = Data(hexString: publicKeyHex) else { return false }

        // Try rawRepresentation (64 bytes) or x963Representation (65 bytes)
        let publicKey: P256.Signing.PublicKey
        if let key = try? P256.Signing.PublicKey(rawRepresentation: pubKeyData) {
            publicKey = key
        } else if let key = try? P256.Signing.PublicKey(x963Representation: pubKeyData) {
            publicKey = key
        } else {
            return false
        }

        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureRaw) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: data)
    }

    /// Computes a standardized short fingerprint for a public key hex string (SHA-256 prefix/suffix).
    public static func computeFingerprint(for publicKeyHex: String) -> String {
        guard let data = Data(hexString: publicKeyHex) else { return publicKeyHex }
        let digest = SHA256.hash(data: data)
        let hexDigest = digest.map { String(format: "%02X", $0) }.joined()
        let prefix = hexDigest.prefix(4)
        let suffix = hexDigest.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}

// MARK: - Hex String Extension

extension Data {
    public init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
