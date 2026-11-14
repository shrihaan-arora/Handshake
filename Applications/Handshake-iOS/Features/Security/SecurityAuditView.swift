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
                            Text(status.trustLevel == .paired ? "Mutual Verification Active" : "Ready to Pair")
                                .font(.headline)
                        }

                        Text(status.trustLevel == .paired ?
                             "All communications are hardware-pinned and end-to-end encrypted with zero cloud intermediation." :
                             "Cryptographic engine initialized. Pair with your Mac companion to establish hardware-pinned mutual trust.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, HandshakeTheme.Spacing.xs)
                }

                Section("Trust & Identity") {
                    AuditItemRow(
                        title: "Device Identity",
                        value: status.isHardwareBacked ? "NIST P-256 (Secure Enclave)" : "NIST P-256 (Keychain Protected)",
                        icon: "key.fill"
                    )
                    AuditItemRow(title: "Key Storage", value: "Keychain (This Device Only)", icon: "lock.shield.fill")
                    AuditItemRow(title: "Trust Status", value: status.trustLevel.rawValue, icon: "person.badge.shield.checkmark.fill")
                }

                Section("Cryptographic Primitives") {
                    AuditItemRow(title: "Framework", value: "Apple CryptoKit (Native)", icon: "apple.logo")
                    AuditItemRow(title: "Transport Security", value: "Local Wi-Fi & BLE Direct", icon: "lock.fill")
                    AuditItemRow(title: "Message Cipher", value: "AES-256-GCM (Authenticated)", icon: "shield.fill")
                    AuditItemRow(title: "Key Agreement", value: "P-256 ECDH / HKDF-SHA256", icon: "arrow.triangle.swap")
                }

                Section("Network & Boundary") {
                    AuditItemRow(title: "Cloud Infrastructure", value: "0 Servers (Zero-Cloud)", icon: "cloud.slash.fill")
                    AuditItemRow(title: "Telemetry / Tracking", value: "None (100% Local-First)", icon: "antenna.radiowaves.left.and.right.slash")
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
