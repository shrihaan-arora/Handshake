import Foundation
import CryptoKit

/// Canonical pairing transcript utility ensuring strict, collision-free binding
/// across both devices during mutual device pairing.
public enum PairingTranscript {
    public static func buildTranscript(
        hostEphemeralPublicKeyHex: String,
        clientEphemeralPublicKeyHex: String,
        hostIdentityPublicKeyHex: String,
        clientIdentityPublicKeyHex: String,
        nonce: String,
        invitationId: UUID
    ) -> Data {
        var buffer = Data()
        // Length-prefixed components to prevent delimiter collision
        func appendPrefixed(_ str: String) {
            let data = str.data(using: .utf8) ?? Data()
            var len = UInt16(data.count).bigEndian
            withUnsafeBytes(of: &len) { buffer.append(contentsOf: $0) }
            buffer.append(data)
        }

        appendPrefixed(hostEphemeralPublicKeyHex)
        appendPrefixed(clientEphemeralPublicKeyHex)
        appendPrefixed(hostIdentityPublicKeyHex)
        appendPrefixed(clientIdentityPublicKeyHex)
        appendPrefixed(nonce)
        withUnsafeBytes(of: invitationId.uuid) { buffer.append(contentsOf: $0) }
        return buffer
    }
}

public enum PairingError: Error, LocalizedError, Equatable {
    case invitationExpired
    case invitationReused
    case invitationMismatch
    case invalidPeerKey
    case transcriptVerificationFailed
    case unapproved
    case handshakeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invitationExpired:
            return "The pairing invitation has expired."
        case .invitationReused:
            return "The pairing invitation has already been consumed."
        case .invitationMismatch:
            return "The invitation identifier does not match the active session."
        case .invalidPeerKey:
            return "The peer provided an invalid public key."
        case .transcriptVerificationFailed:
            return "Digital signature verification over the pairing transcript failed."
        case .unapproved:
            return "The pairing request was rejected by the user."
        case .handshakeFailed(let msg):
            return "Pairing handshake failed: \(msg)"
        }
    }
}

// MARK: - Host Pairing Session (Mac)

/// Actor managing the state of an active pairing session on the host Mac.
/// Fully thread-safe and isolated under Swift 6 strict concurrency.
public actor HostPairingSession {
    public nonisolated let invitation: PairingInvitation
    private let hostEphemeral: EphemeralKeyExchange
    private let hostIdentity: CryptoIdentity

    private var isConsumed: Bool = false
    private var clientIdentity: DeviceIdentity?
    private var transcript: Data?
    private var sharedSecret: SharedSecret?
    private var derivedSAS: String?

    public init(
        hostIdentity: CryptoIdentity,
        lifetimeSeconds: TimeInterval = 120,
        localPort: UInt16 = 5894,
        serviceName: String = "Handshake-Host"
    ) {
        self.hostIdentity = hostIdentity
        self.hostEphemeral = EphemeralKeyExchange()
        let invitationId = UUID()
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        self.invitation = PairingInvitation(
            id: invitationId,
            hostIdentity: hostIdentity.identity,
            ephemeralPublicKeyHex: hostEphemeral.publicKeyHex,
            localPort: localPort,
            serviceName: serviceName,
            nonce: nonce,
            createdAt: Date(),
            lifetimeSeconds: lifetimeSeconds
        )
    }

    /// Processes an incoming `PairingRequest` from an iPhone scanning the QR code.
    /// Returns the `PairingResponse` to transmit over the wire and the independently derived SAS code.
    public func processRequest(_ request: PairingRequest) throws -> (response: PairingResponse, derivedSAS: String) {
        // 1. Validate invitation freshness & consumption
        guard !isConsumed else { throw PairingError.invitationReused }
        guard !invitation.isExpired() else { throw PairingError.invitationExpired }
        guard request.invitationId == invitation.id else { throw PairingError.invitationMismatch }

        // 2. Compute mutual ECDH shared secret
        let sharedSecret = try hostEphemeral.computeSharedSecret(
            peerEphemeralPublicKeyHex: request.clientEphemeralPublicKeyHex
        )

        // 3. Build canonical transcript
        let transcript = PairingTranscript.buildTranscript(
            hostEphemeralPublicKeyHex: hostEphemeral.publicKeyHex,
            clientEphemeralPublicKeyHex: request.clientEphemeralPublicKeyHex,
            hostIdentityPublicKeyHex: hostIdentity.identity.publicKeyHex,
            clientIdentityPublicKeyHex: request.clientIdentity.publicKeyHex,
            nonce: invitation.nonce,
            invitationId: invitation.id
        )

        // 4. Derive SAS code independently
        let nonceData = invitation.nonce.data(using: .utf8) ?? Data()
        let sasCode = EphemeralKeyExchange.deriveSAS(
            sharedSecret: sharedSecret,
            salt: nonceData,
            transcript: transcript
        )

        // 5. Host signs (Transcript || "HOST-OFFER")
        var offerData = transcript
        offerData.append("HOST-OFFER".data(using: .utf8)!)
        let hostSignature = try hostIdentity.sign(data: offerData)

        // Save session state
        self.clientIdentity = request.clientIdentity
        self.transcript = transcript
        self.sharedSecret = sharedSecret
        self.derivedSAS = sasCode

        let response = PairingResponse(
            invitationId: invitation.id,
            hostIdentity: hostIdentity.identity,
            hostEphemeralPublicKeyHex: hostEphemeral.publicKeyHex,
            hostSignatureHex: hostSignature.hexString,
            sasFingerprintCode: "" // Omit SAS from wire
        )

        return (response, sasCode)
    }

    /// Processes the iPhone's `PairingConfirmation`, validating the client's signature over the transcript.
    /// Upon user approval, records the trusted peer in `TrustStore` and consumes the invitation.
    public func processConfirmation(
        _ confirmation: PairingConfirmation,
        trustStore: TrustStore
    ) async throws -> (completion: PairingCompletion, establishedRecord: TrustRecord) {
        guard !isConsumed else {
            throw PairingError.invitationReused
        }
        guard confirmation.invitationId == invitation.id else {
            throw PairingError.invitationMismatch
        }
        guard confirmation.isApproved else {
            throw PairingError.unapproved
        }
        guard let clientIdentity = self.clientIdentity,
              let transcript = self.transcript else {
            throw PairingError.handshakeFailed("Session state incomplete")
        }

        // Verify client's signature over (Transcript || "CONFIRM")
        var confirmData = transcript
        confirmData.append("CONFIRM".data(using: .utf8)!)
        guard let clientSigData = Data(hexString: confirmation.clientSignatureHex),
              CryptoIdentity.verify(
                signatureRaw: clientSigData,
                for: confirmData,
                publicKeyHex: clientIdentity.publicKeyHex
              ) else {
            throw PairingError.transcriptVerificationFailed
        }

        // Host signs (Transcript || "ACCEPT")
        var acceptData = transcript
        acceptData.append("ACCEPT".data(using: .utf8)!)
        let hostApprovalSig = try hostIdentity.sign(data: acceptData)

        // Mark consumed (Single-use enforcement)
        self.isConsumed = true

        // Establish and persist trust record
        let trustRecord = TrustRecord(
            peer: clientIdentity,
            pairedAt: Date(),
            lastSeenAt: Date(),
            isRevoked: false,
            authorizedCapabilities: [.lockScreen, .sleep]
        )
        try await trustStore.addOrUpdate(trustRecord)

        let completion = PairingCompletion(
            invitationId: invitation.id,
            isSuccessful: true,
            hostApprovalSignatureHex: hostApprovalSig.hexString,
            establishedTrustRecord: trustRecord
        )

        return (completion, trustRecord)
    }
}

// MARK: - Client Pairing Session (iPhone)

/// Actor managing the state of an active pairing session on the client iPhone.
/// Fully thread-safe and isolated under Swift 6 strict concurrency.
public actor ClientPairingSession {
    public nonisolated let invitation: PairingInvitation
    private let clientIdentity: CryptoIdentity
    private let clientEphemeral: EphemeralKeyExchange

    private var transcript: Data?
    private var sharedSecret: SharedSecret?
    private var derivedSAS: String?
    private var hostEphemeralHex: String?

    public init(
        invitation: PairingInvitation,
        clientIdentity: CryptoIdentity
    ) throws {
        guard !invitation.isExpired() else { throw PairingError.invitationExpired }
        self.invitation = invitation
        self.clientIdentity = clientIdentity
        self.clientEphemeral = EphemeralKeyExchange()
    }

    /// Creates the initial `PairingRequest` to send to the host Mac.
    public func createRequest() -> PairingRequest {
        PairingRequest(
            invitationId: invitation.id,
            clientIdentity: clientIdentity.identity,
            clientEphemeralPublicKeyHex: clientEphemeral.publicKeyHex,
            nonceProofHex: invitation.nonce
        )
    }

    /// Processes the `PairingResponse` received from the Mac.
    /// Verifies the Mac's identity signature and derives the 6-digit SAS code independently.
    public func processResponse(_ response: PairingResponse) throws -> String {
        guard response.invitationId == invitation.id else { throw PairingError.invitationMismatch }
        guard response.hostIdentity.publicKeyHex.lowercased() == invitation.hostIdentity.publicKeyHex.lowercased() else {
            throw PairingError.invalidPeerKey
        }

        // 1. Mutual ECDH key agreement
        let sharedSecret = try clientEphemeral.computeSharedSecret(
            peerEphemeralPublicKeyHex: response.hostEphemeralPublicKeyHex
        )

        // 2. Canonical transcript
        let transcript = PairingTranscript.buildTranscript(
            hostEphemeralPublicKeyHex: response.hostEphemeralPublicKeyHex,
            clientEphemeralPublicKeyHex: clientEphemeral.publicKeyHex,
            hostIdentityPublicKeyHex: invitation.hostIdentity.publicKeyHex,
            clientIdentityPublicKeyHex: clientIdentity.identity.publicKeyHex,
            nonce: invitation.nonce,
            invitationId: invitation.id
        )

        // 3. Verify host's signature over (Transcript || "HOST-OFFER")
        var offerData = transcript
        offerData.append("HOST-OFFER".data(using: .utf8)!)
        guard let hostSigData = Data(hexString: response.hostSignatureHex),
              CryptoIdentity.verify(
                signatureRaw: hostSigData,
                for: offerData,
                publicKeyHex: invitation.hostIdentity.publicKeyHex
              ) else {
            throw PairingError.transcriptVerificationFailed
        }

        // 4. Derive SAS code independently
        let nonceData = invitation.nonce.data(using: .utf8) ?? Data()
        let sasCode = EphemeralKeyExchange.deriveSAS(
            sharedSecret: sharedSecret,
            salt: nonceData,
            transcript: transcript
        )

        self.transcript = transcript
        self.sharedSecret = sharedSecret
        self.derivedSAS = sasCode
        self.hostEphemeralHex = response.hostEphemeralPublicKeyHex

        return sasCode
    }

    /// Creates the user's explicit approval `PairingConfirmation`, signed with the iPhone's identity key.
    public func createConfirmation(isApproved: Bool) throws -> PairingConfirmation {
        guard let transcript = self.transcript else {
            throw PairingError.handshakeFailed("Transcript missing")
        }

        if !isApproved {
            return PairingConfirmation(invitationId: invitation.id, isApproved: false)
        }

        // Sign (Transcript || "CONFIRM")
        var confirmData = transcript
        confirmData.append("CONFIRM".data(using: .utf8)!)
        let clientSig = try clientIdentity.sign(data: confirmData)

        return PairingConfirmation(
            invitationId: invitation.id,
            isApproved: true,
            clientSignatureHex: clientSig.hexString,
            confirmedSASCode: self.derivedSAS ?? ""
        )
    }

    /// Validates the final `PairingCompletion` from the Mac and registers the host Mac in the client `TrustStore`.
    public func completePairing(
        _ completion: PairingCompletion,
        trustStore: TrustStore
    ) async throws -> TrustRecord {
        guard completion.invitationId == invitation.id else {
            throw PairingError.invitationMismatch
        }
        guard completion.isSuccessful else {
            throw PairingError.unapproved
        }
        guard let transcript = self.transcript else {
            throw PairingError.handshakeFailed("Session transcript missing")
        }

        // Verify host's approval signature over (Transcript || "ACCEPT")
        var acceptData = transcript
        acceptData.append("ACCEPT".data(using: .utf8)!)
        guard let hostApprovalSigData = Data(hexString: completion.hostApprovalSignatureHex),
              CryptoIdentity.verify(
                signatureRaw: hostApprovalSigData,
                for: acceptData,
                publicKeyHex: invitation.hostIdentity.publicKeyHex
              ) else {
            throw PairingError.transcriptVerificationFailed
        }

        // Create and store host trust record on iPhone
        let trustRecord = TrustRecord(
            peer: invitation.hostIdentity,
            pairedAt: Date(),
            lastSeenAt: Date(),
            isRevoked: false,
            authorizedCapabilities: [.lockScreen, .sleep]
        )
        try await trustStore.addOrUpdate(trustRecord)
        return trustRecord
    }
}
