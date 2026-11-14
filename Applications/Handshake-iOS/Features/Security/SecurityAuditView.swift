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
                            Image(systemName: status.trustLevel == .paired ? "checkmark.shield.fill" : "shield")
                                .font(.title2)
                                .foregroundStyle(status.trustLevel == .paired ? .green : .secondary)
                            Text(status.trustLevel == .paired ? "Mutual Verification Active" : "Phase 1 Architecture Baseline")
                                .font(.headline)
                        }

                        Text(status.trustLevel == .paired ?
                             "All communications are hardware-pinned and end-to-end encrypted." :
                             "Phase 1 establishes architectural models. Cryptographic key generation, mutual TLS, and QR pairing will be implemented and verified in Phase 2.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, HandshakeTheme.Spacing.xs)
                }

                Section("Trust & Identity") {
                    AuditItemRow(title: "Device Identity", value: "Keypair (Pending Phase 2)", icon: "key.fill")
                    AuditItemRow(title: "Key Storage", value: "Keychain (Device Only)", icon: "lock.shield.fill")
                    AuditItemRow(title: "Trust Status", value: status.trustLevel.rawValue, icon: "person.badge.shield.checkmark.fill")
                }

                Section("Cryptographic Primitives (Planned Phase 2)") {
                    AuditItemRow(title: "Framework", value: "Apple CryptoKit (Native)", icon: "apple.logo")
                    AuditItemRow(title: "Transport Security", value: "TLS 1.3 (Scheduled)", icon: "lock.fill")
                    AuditItemRow(title: "Message Cipher", value: "AES-256-GCM AEAD (Scheduled)", icon: "shield.fill")
                    AuditItemRow(title: "Key Agreement", value: "ECDH / HKDF-SHA256 (Scheduled)", icon: "arrow.triangle.swap")
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

