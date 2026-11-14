import SwiftUI
import HandshakeCore

public struct SecurityShieldBadge: View {
    public let status: SecurityStatus

    public init(status: SecurityStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: HandshakeTheme.Spacing.xs) {
            Image(systemName: "checkmark.shield.fill")
                .font(.caption)
                .foregroundStyle(.green)

            Text("Hardware-Pinned E2EE")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, HandshakeTheme.Spacing.xs + 2)
        .padding(.vertical, 3)
        .background(Color.green.opacity(0.08), in: Capsule())
    }
}
