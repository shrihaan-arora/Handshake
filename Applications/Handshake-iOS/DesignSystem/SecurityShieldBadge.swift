import SwiftUI
import HandshakeCore

public struct SecurityShieldBadge: View {
    public let status: SecurityStatus

    public init(status: SecurityStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: HandshakeTheme.Spacing.xs) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(iconColor)

            Text(badgeTitle)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, HandshakeTheme.Spacing.xs + 2)
        .padding(.vertical, 3)
        .background(backgroundColor, in: Capsule())
    }

    private var isVerified: Bool {
        status.trustLevel == .paired && status.isTransportEncrypted && status.isApplicationEncrypted
    }

    private var iconName: String {
        isVerified ? "checkmark.shield.fill" : "shield"
    }

    private var iconColor: Color {
        isVerified ? .green : .secondary
    }

    private var badgeTitle: String {
        isVerified ? "Hardware-Pinned E2EE" : "Phase 1 Preview (Unverified)"
    }

    private var backgroundColor: Color {
        isVerified ? Color.green.opacity(0.08) : Color.primary.opacity(0.05)
    }
}

