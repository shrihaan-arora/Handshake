import SwiftUI
import CoreImage
import HandshakeCore

#if canImport(AppKit)
import AppKit
#endif

public struct MacPairingView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject public var viewModel: MacDashboardViewModel

    public init(viewModel: MacDashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: MacTheme.Spacing.lg) {
            switch viewModel.pairingState {
            case .advertising(let invitation):
                advertisingView(invitation: invitation)
            case .awaitingApproval(let client, let sasCode):
                awaitingApprovalView(client: client, sasCode: sasCode)
            case .completed(let client):
                completedView(client: client)
            case .failed(let reason):
                failedView(reason: reason)
            case .idle:
                EmptyView()
            }
        }
        .padding(MacTheme.Spacing.xl)
        .frame(width: 460)
    }

    // MARK: - State Views

    private func advertisingView(invitation: PairingInvitation) -> some View {
        VStack(spacing: MacTheme.Spacing.md) {
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
                        .accessibilityLabel("Pairing QR Code. Scan with Handshake app on your iPhone.")
                }

                // Expiration timer
                HStack(spacing: MacTheme.Spacing.xs) {
                    Image(systemName: "clock")
                        .font(.caption)
                    Text("Invitation expires in \(invitation.remainingSeconds())s")
                        .font(.caption)
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }

            // Security note & BLE indicator
            VStack(spacing: MacTheme.Spacing.xs) {
                HStack(spacing: MacTheme.Spacing.xs) {
                    Image(systemName: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text("Zero private keys in QR. Hardware-pinned during mutual handshake.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: MacTheme.Spacing.xs) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text("Bluetooth LE Pairing Active • Direct zero-camera discovery ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Cancel Button
            HStack {
                Button("Cancel") {
                    viewModel.dismissPairingFlow()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()
            }
        }
    }

    private func awaitingApprovalView(client: DeviceIdentity, sasCode: String) -> some View {
        VStack(spacing: MacTheme.Spacing.lg) {
            // Header
            VStack(spacing: 4) {
                Image(systemName: "iphone.badge.play")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)

                Text("Pairing Request")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("\(client.displayName) (\(client.modelIdentifier)) is requesting to pair.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // SAS Verification Fingerprint
            MacCard {
                VStack(spacing: 4) {
                    Text("SECURITY CODE (SAS)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .tracking(1.5)
                        .foregroundStyle(.secondary)

                    Text(sasCode)
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .tracking(2.0)

                    Text("Confirm this 6-digit code matches your iPhone screen before approving.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, MacTheme.Spacing.xs)
            }

            // Bilateral Action Buttons
            HStack(spacing: MacTheme.Spacing.md) {
                Button("Reject") {
                    viewModel.rejectPairing()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Approve & Pair") {
                    viewModel.approvePairing()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func completedView(client: DeviceIdentity) -> some View {
        VStack(spacing: MacTheme.Spacing.lg) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            VStack(spacing: 4) {
                Text("Pairing Complete")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("\(client.displayName) is now cryptographically trusted and pinned.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button("Done") {
                viewModel.dismissPairingFlow()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.vertical, MacTheme.Spacing.md)
    }

    private func failedView(reason: String) -> some View {
        VStack(spacing: MacTheme.Spacing.lg) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            VStack(spacing: 4) {
                Text("Pairing Failed")
                    .font(.title2)
                    .fontWeight(.bold)

                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Dismiss") {
                viewModel.dismissPairingFlow()
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, MacTheme.Spacing.md)
    }

    // MARK: - QR Generator

    private func generateQRCode(from string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        guard let data = string.data(using: .utf8) else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputCIImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledCIImage = outputCIImage.transformed(by: transform)

        let rep = NSCIImageRep(ciImage: scaledCIImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}
