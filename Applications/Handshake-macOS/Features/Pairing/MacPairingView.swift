import SwiftUI
import CoreImage
import HandshakeCore

#if canImport(AppKit)
import AppKit
#endif

public struct MacPairingView: View {
    @Environment(\.dismiss) private var dismiss
    public let invitation: PairingInvitation
    @State private var timeRemaining: Int

    public init(invitation: PairingInvitation) {
        self.invitation = invitation
        self._timeRemaining = State(initialValue: invitation.remainingSeconds())
    }

    public var body: some View {
        VStack(spacing: MacTheme.Spacing.lg) {
            // Header
            VStack(spacing: 4) {
                Text("Pair iPhone")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Scan this QR code with the Handshake app on your iPhone")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // QR Code Container
            VStack(spacing: MacTheme.Spacing.sm) {
                if let qrImage = generateQRCode(from: invitation.qrPayloadString) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(MacTheme.Spacing.md)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: MacTheme.Radius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: MacTheme.Radius.md, style: .continuous)
                                .stroke(MacTheme.Colors.hairline, lineWidth: 1)
                        )
                }

                // Expiration timer
                HStack(spacing: MacTheme.Spacing.xs) {
                    Image(systemName: "clock")
                        .font(.caption)
                    Text("Invitation expires in \(timeRemaining)s")
                        .font(.caption)
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }

            // SAS Verification Fingerprint
            MacCard {
                VStack(spacing: 4) {
                    Text("VERIFICATION CODE (SAS)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .tracking(1.0)
                        .foregroundStyle(.secondary)

                    Text(invitation.verificationCode)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)

                    Text("Confirm this 6-digit code matches your iPhone screen before approving.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }

            // Security note
            HStack(spacing: MacTheme.Spacing.xs) {
                Image(systemName: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("Zero private keys in QR. Hardware-pinned during mutual handshake.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Action Buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(MacTheme.Spacing.xl)
        .frame(width: 440)
    }

    private func generateQRCode(from string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        guard let data = string.data(using: .utf8) else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputCIImage = filter.outputImage else { return nil }
        // Scale up sharp pixels
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledCIImage = outputCIImage.transformed(by: transform)

        let rep = NSCIImageRep(ciImage: scaledCIImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}

