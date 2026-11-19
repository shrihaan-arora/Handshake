import Foundation

/// Diagnostic lifecycle stages during mutual device pairing.
/// Used for real-time UI progression, bounded timeout tracking, and security auditing.
public enum PairingStage: Sendable, Equatable {
    /// No pairing attempt is active.
    case notStarted
    /// Step 1: Camera detected raw QR code payload.
    case qrDetected
    /// Step 2: Parsing URL components and parameters.
    case invitationParsing
    /// Step 3: Validating invitation TTL, clock skew, and cryptographic key formats.
    case invitationValidating
    /// Step 4: Probing direct IP address or discovering Bonjour service advertisement.
    case resolvingHost(hostName: String)
    /// Step 5: Opening direct local TCP socket.
    case connectingSocket(endpoint: String)
    /// Step 6: Exchanging ephemeral P-256 public keys.
    case exchangingEphemeralKeys
    /// Step 7: PairingRequest transmitted; awaiting host Mac response.
    case waitingForMacResponse
    /// Step 8: Computing mutual ECDH shared secret and HKDF-SHA256 transcript binding.
    case derivingVerificationCode
    /// Step 9: SAS code derived; awaiting mutual user confirmation on both screens.
    case waitingForMutualConfirmation(sasCode: String)
    /// Step 10: Signing and transmitting bilateral confirmation.
    case sendingConfirmation
    /// Step 11: Pairing completed; peer pinned in Keychain/TrustStore.
    case pairingCompleted(peer: DeviceIdentity)
    /// Step 12: Pairing failed with explicit actionable reason.
    case pairingFailed(reason: String)

    public var title: String {
        switch self {
        case .notStarted: return "Ready to Pair"
        case .qrDetected: return "QR Code Detected"
        case .invitationParsing: return "Reading Invitation..."
        case .invitationValidating: return "Validating Parameters..."
        case .resolvingHost(let host): return "Locating \(host)..."
        case .connectingSocket: return "Connecting to Mac..."
        case .exchangingEphemeralKeys: return "Exchanging Keys..."
        case .waitingForMacResponse: return "Waiting for Mac Response..."
        case .derivingVerificationCode: return "Deriving Security Code..."
        case .waitingForMutualConfirmation: return "Confirm Security Code"
        case .sendingConfirmation: return "Submitting Confirmation..."
        case .pairingCompleted: return "Pairing Complete"
        case .pairingFailed: return "Pairing Failed"
        }
    }

    public var detail: String {
        switch self {
        case .notStarted:
            return "Waiting for a QR-initiated pairing attempt."
        case .qrDetected:
            return "Local pairing QR code read from camera."
        case .invitationParsing:
            return "Extracting host identity and transport endpoints."
        case .invitationValidating:
            return "Verifying cryptographic keys and expiration window."
        case .resolvingHost(let host):
            return "Resolving direct Wi-Fi route to '\(host)'."
        case .connectingSocket(let ep):
            return "Opening secure local TCP channel to \(ep)."
        case .exchangingEphemeralKeys:
            return "Generating ephemeral P-256 key pair."
        case .waitingForMacResponse:
            return "Pairing request transmitted. Awaiting Mac response."
        case .derivingVerificationCode:
            return "Deriving 6-digit Short Authentication String (SAS)."
        case .waitingForMutualConfirmation(let code):
            return "Confirm this code matches your Mac screen: \(code)"
        case .sendingConfirmation:
            return "Signing bilateral confirmation with hardware identity."
        case .pairingCompleted(let peer):
            return "'\(peer.displayName)' is cryptographically pinned and trusted."
        case .pairingFailed(let reason):
            return reason
        }
    }

    public var sfSymbolName: String {
        switch self {
        case .notStarted: return "qrcode.viewfinder"
        case .qrDetected: return "qrcode"
        case .invitationParsing: return "doc.text.magnifyingglass"
        case .invitationValidating: return "checkmark.shield"
        case .resolvingHost: return "network"
        case .connectingSocket: return "cable.connector"
        case .exchangingEphemeralKeys: return "key.fill"
        case .waitingForMacResponse: return "arrow.up.and.down.circle"
        case .derivingVerificationCode: return "lock.rotation"
        case .waitingForMutualConfirmation: return "shield.checkered"
        case .sendingConfirmation: return "arrow.up.circle.fill"
        case .pairingCompleted: return "checkmark.seal.fill"
        case .pairingFailed: return "xmark.octagon.fill"
        }
    }
}
