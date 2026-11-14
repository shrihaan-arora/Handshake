import SwiftUI
import HandshakeCore

public struct PairingScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isSimulatingScan: Bool = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HandshakeTheme.Spacing.lg) {
                    // Viewfinder area
                    ZStack {
                        RoundedRectangle(cornerRadius: HandshakeTheme.Radius.lg, style: .continuous)
                            .fill(Color.black.opacity(0.85))
                            .frame(height: 280)

                        // Reticle outline
                        RoundedRectangle(cornerRadius: HandshakeTheme.Radius.md, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [10, 5]))
                            .frame(width: 200, height: 200)

                        VStack(spacing: HandshakeTheme.Spacing.sm) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 48, weight: .light))
                                .foregroundStyle(.white.opacity(0.8))

                            Text("Scan Mac QR Code")
                                .font(.headline)
                                .foregroundStyle(.white)

                            Text("Align the QR code displayed on your Mac screen within the frame.")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, HandshakeTheme.Spacing.lg)
                        }
                    }
                    .padding(.horizontal, HandshakeTheme.Spacing.md)

                    // Security Protocol Walkthrough
                    HandshakeCard {
                        Label("Secure Pairing Protocol", systemImage: "shield.lefthalf.filled")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text("Handshake establishes mutual hardware trust through an out-of-band ephemeral key agreement:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: HandshakeTheme.Spacing.xs) {
                            ProtocolStepRow(number: "1", title: "Single-Use Invitation", detail: "Mac generates short-lived QR invitation (no private keys).")
                            ProtocolStepRow(number: "2", title: "Local Discovery", detail: "iPhone contacts Mac over local Wi-Fi or BLE.")
                            ProtocolStepRow(number: "3", title: "Key Exchange", detail: "Mutual ECDH agreement with HKDF-SHA256 derivation.")
                            ProtocolStepRow(number: "4", title: "Visual SAS Verification", detail: "Both devices show identical 6-digit confirmation code.")
                            ProtocolStepRow(number: "5", title: "Keychain Pinning", detail: "Public identity keys are permanently pinned locally.")
                        }
                        .padding(.top, HandshakeTheme.Spacing.xs)
                    }
                    .padding(.horizontal, HandshakeTheme.Spacing.md)

                    // Phase 1 notice
                    Text("Phase 1 Preview: Cryptographic pairing handshake will be executed in Phase 2.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, HandshakeTheme.Spacing.lg)
                }
                .padding(.vertical, HandshakeTheme.Spacing.md)
            }
            .navigationTitle("Pair New Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ProtocolStepRow: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: HandshakeTheme.Spacing.sm) {
            Text(number)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Color.primary.opacity(0.06), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

