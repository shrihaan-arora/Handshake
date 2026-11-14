import SwiftUI
import HandshakeCore

public struct StatusPillView: View {
    public let state: ConnectionState

    public init(state: ConnectionState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: HandshakeTheme.Spacing.xs) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)

            Text(state.statusTitle)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)

            if let transport = state.transport {
                Image(systemName: transport.sfSymbolName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, HandshakeTheme.Spacing.sm)
        .padding(.vertical, HandshakeTheme.Spacing.xs + 2)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(HandshakeTheme.Colors.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Connection status: \(state.statusTitle)"))
    }

    private var indicatorColor: Color {
        switch state {
        case .connected:
            return HandshakeTheme.Colors.connected
        case .connecting, .discovering:
            return HandshakeTheme.Colors.connecting
        case .disconnected:
            return HandshakeTheme.Colors.disconnected
        case .failed:
            return HandshakeTheme.Colors.destructive
        }
    }
}

