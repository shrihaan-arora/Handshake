import SwiftUI
import HandshakeCore

public struct MenuBarView: View {
    @ObservedObject public var viewModel: MacDashboardViewModel
    public let openMainWindow: () -> Void

    public init(viewModel: MacDashboardViewModel, openMainWindow: @escaping () -> Void) {
        self.viewModel = viewModel
        self.openMainWindow = openMainWindow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Status
            HStack(spacing: MacTheme.Spacing.xs) {
                Circle()
                    .fill(viewModel.isAvailableForControl ? MacTheme.Colors.connected : MacTheme.Colors.idle)
                    .frame(width: 8, height: 8)

                Text(viewModel.isAvailableForControl ? "Handshake: Available" : "Handshake: Inactive")
                    .font(.headline)

                Spacer()
            }
            .padding(.horizontal, MacTheme.Spacing.md)
            .padding(.vertical, MacTheme.Spacing.sm)

            Divider()

            // Active Connection info
            if let peer = viewModel.connectionState.connectedPeer {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ACTIVE PEER")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack {
                        Image(systemName: peer.deviceType.sfSymbolName)
                        Text(peer.displayName)
                            .font(.subheadline)
                    }
                }
                .padding(.horizontal, MacTheme.Spacing.md)
                .padding(.vertical, MacTheme.Spacing.xs)

                Divider()
            }

            // Quick Actions
            Button {
                viewModel.startPairingFlow()
                openMainWindow()
            } label: {
                Label("Pair New Device...", systemImage: "qrcode")
            }
            .padding(.horizontal, MacTheme.Spacing.md)
            .padding(.vertical, 4)

            Button {
                viewModel.toggleAvailability()
            } label: {
                Label(viewModel.isAvailableForControl ? "Turn Off Availability" : "Make Mac Available",
                      systemImage: viewModel.isAvailableForControl ? "pause.circle" : "play.circle")
            }
            .padding(.horizontal, MacTheme.Spacing.md)
            .padding(.vertical, 4)

            Button {
                openMainWindow()
            } label: {
                Label("Open Handshake Window", systemImage: "macwindow")
            }
            .padding(.horizontal, MacTheme.Spacing.md)
            .padding(.vertical, 4)

            Divider()

            Button("Quit Handshake") {
                NSApplication.shared.terminate(nil)
            }
            .padding(.horizontal, MacTheme.Spacing.md)
            .padding(.vertical, 4)
        }
        .padding(.vertical, 4)
        .frame(width: 260)
    }
}
