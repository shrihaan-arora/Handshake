import Foundation

/// Protocol messages exchanged during the mutual device pairing process.
public enum PairingMessage: Codable, Sendable, Equatable {
    /// Step 1: iPhone initiates connection after reading the Mac QR invitation.
    case request(PairingRequest)

    /// Step 2: Mac returns its identity and ephemeral key parameters.
    case response(PairingResponse)

    /// Step 3: Explicit user confirmation of the Short Authentication String (SAS).
    case confirmation(PairingConfirmation)

    /// Step 4: Final handshake acknowledgment and session completion.
    case completion(PairingCompletion)
}

public struct PairingDiscoveryRequest: Codable, Sendable, Equatable {
    public let clientIdentity: DeviceIdentity
    public let timestamp: Date

    public init(clientIdentity: DeviceIdentity, timestamp: Date = Date()) {
        self.clientIdentity = clientIdentity
        self.timestamp = timestamp
    }
}

public struct PairingOffer: Codable, Sendable, Equatable {
    public let invitation: PairingInvitation
    public let hostSignatureHex: String

    public init(invitation: PairingInvitation, hostSignatureHex: String = "") {
        self.invitation = invitation
        self.hostSignatureHex = hostSignatureHex
    }
}

public struct PairingRequest: Codable, Sendable, Equatable {
    public let invitationId: UUID
    public let clientIdentity: DeviceIdentity
    public let clientEphemeralPublicKeyHex: String
    public let nonceProofHex: String

    public init(
        invitationId: UUID,
        clientIdentity: DeviceIdentity,
        clientEphemeralPublicKeyHex: String,
        nonceProofHex: String
    ) {
        self.invitationId = invitationId
        self.clientIdentity = clientIdentity
        self.clientEphemeralPublicKeyHex = clientEphemeralPublicKeyHex
        self.nonceProofHex = nonceProofHex
    }
}

public struct PairingResponse: Codable, Sendable, Equatable {
    public let invitationId: UUID
    public let hostIdentity: DeviceIdentity
    public let hostEphemeralPublicKeyHex: String
    public let hostSignatureHex: String
    /// Deprecated wire field: SAS must never be trusted across the wire; derived locally by clients.
    public let sasFingerprintCode: String

    public init(
        invitationId: UUID,
        hostIdentity: DeviceIdentity,
        hostEphemeralPublicKeyHex: String,
        hostSignatureHex: String = "",
        sasFingerprintCode: String = ""
    ) {
        self.invitationId = invitationId
        self.hostIdentity = hostIdentity
        self.hostEphemeralPublicKeyHex = hostEphemeralPublicKeyHex
        self.hostSignatureHex = hostSignatureHex
        self.sasFingerprintCode = sasFingerprintCode
    }
}

public struct PairingConfirmation: Codable, Sendable, Equatable {
    public let invitationId: UUID
    public let isApproved: Bool
    public let clientSignatureHex: String
    /// Deprecated wire field: The 6-digit numeric Short Authentication String (SAS) is an out-of-band
    /// visual comparison token and must never be transmitted over the wire. Authentication is cryptographically
    /// bound via `clientSignatureHex` over the complete handshake transcript.
    public let confirmedSASCode: String

    public init(
        invitationId: UUID,
        isApproved: Bool,
        clientSignatureHex: String = "",
        confirmedSASCode: String = ""
    ) {
        self.invitationId = invitationId
        self.isApproved = isApproved
        self.clientSignatureHex = clientSignatureHex
        self.confirmedSASCode = confirmedSASCode
    }
}

public struct PairingCompletion: Codable, Sendable, Equatable {
    public let invitationId: UUID
    public let isSuccessful: Bool
    public let hostApprovalSignatureHex: String
    public let establishedTrustRecord: TrustRecord?

    public init(
        invitationId: UUID,
        isSuccessful: Bool,
        hostApprovalSignatureHex: String = "",
        establishedTrustRecord: TrustRecord? = nil
    ) {
        self.invitationId = invitationId
        self.isSuccessful = isSuccessful
        self.hostApprovalSignatureHex = hostApprovalSignatureHex
        self.establishedTrustRecord = establishedTrustRecord
    }
}
