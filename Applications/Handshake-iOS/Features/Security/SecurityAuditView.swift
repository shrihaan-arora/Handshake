import SwiftUI
import HandshakeCore

public struct SecurityAuditView: View {
    @Environment(\.dismiss) private var dismiss
    public let status: SecurityStatus

    public init(status: SecurityStatus) {
        self.status = status
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: HandshakeTheme.Spacing.xs) {
                        HStack(spacing: HandshakeTheme.Spacing.xs) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.title2)
                                .foregroundStyle(.green)
                            Text("Security Baseline Active")
                                .font(.headline)
                        }

                        Text("Handshake is architected around Apple-native zero-trust cryptography. No cloud intermediaries or third-party telemetry exist.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, HandshakeTheme.Spacing.xs)
                }

                Section("Trust & Identity") {
                    AuditItemRow(title: "Device Identity", value: "Hardware Keypair (P-256 / Ed25519)", icon: "key.fill")
                    AuditItemRow(title: "Key Storage", value: "Apple Keychain (Device Only)", icon: "lock.shield.fill")
                    AuditItemRow(title: "Trust Level", value: status.trustLevel.rawValue, icon: "person.badge.shield.checkmark.fill")
                }

                Section("Cryptographic Primitives") {
                    AuditItemRow(title: "Framework", value: "Apple CryptoKit (Native)", icon: "apple.logo")
                    AuditItemRow(title: "Transport Security", value: "TLS 1.3 (Network.framework)", icon: "lock.fill")
                    AuditItemRow(title: "Message Cipher", value: "AES-256-GCM / Poly1305 AEAD", icon: "shield.fill")
                    AuditItemRow(title: "Key Agreement", value: "X25519 / HKDF-SHA256", icon: "arrow.triangle.swap")
                }

                Section("Network & Boundary") {
                    AuditItemRow(title: "Cloud Infrastructure", value: "0 Servers (Zero-Cloud)", icon: "cloud.slash.fill")
                    AuditItemRow(title: "Telemetry / Tracking", value: "Disabled / None", icon: "antenna.radiowaves.left.and.right.slash")
                    AuditItemRow(title: "Replay Protection", value: "Monotonic Sequence + 30s Window", icon: "clock.arrow.circlepath")
                }
            }
            .navigationTitle("Security Posture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct AuditItemRow: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack {
            Label {
                Text(title)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(.blue)
            }

            Spacer()

            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
