import SwiftUI
import HandshakeCore

public struct MacDashboardView: View {
    @ObservedObject public var viewModel: MacDashboardViewModel

    public init(viewModel: MacDashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MacTheme.Spacing.lg) {
                // Header Bar
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HANDSHAKE")
                            .font(.caption)
                            .fontWeight(.bold)
                            .tracking(2.0)
                            .foregroundStyle(.secondary)

                        Text("Host Companion")
                            .font(.title)
                            .fontWeight(.bold)
                    }

                    Spacer()

                    // Mac Availability Toggle
                    HStack(spacing: MacTheme.Spacing.sm) {
                        Circle()
                            .fill(viewModel.isAvailableForControl ? MacTheme.Colors.connected : MacTheme.Colors.idle)
                            .frame(width: 10, height: 10)

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(viewModel.isAvailableForControl ? "Available" : "Inactive")
                                .font(.headline)
                            Text(viewModel.isAvailableForControl ? "Ready for iPhone commands" : "Remote listeners paused")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Toggle("Mac Availability", isOn: Binding(
                            get: { viewModel.isAvailableForControl },
                            set: { _ in viewModel.toggleAvailability() }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("Mac Availability for Local Control")
                        .accessibilityValue(viewModel.isAvailableForControl ? "Available" : "Inactive")
                        .accessibilityHint("Toggles whether this Mac listens for commands from paired devices")
                    }
                    .padding(.horizontal, MacTheme.Spacing.md)
                    .padding(.vertical, MacTheme.Spacing.xs)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: MacTheme.Radius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: MacTheme.Radius.md)
                            .stroke(MacTheme.Colors.hairline, lineWidth: 1)
                    )
                }

                // Connection & Listener Status Card
                MacCard {
                    HStack(spacing: MacTheme.Spacing.lg) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Local Network Transport", systemImage: "wifi")
                                .font(.headline)
                            Text("TLS 1.3 listener on port 5894 (Bonjour: _handshake._tcp)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Local Network Transport: TLS 1.3 listener on port 5894, Bonjour service handshake")

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Label("Bluetooth Low Energy", systemImage: "dot.radiowaves.left.and.right")
                                .font(.headline)
                            Text("Peripheral advertisement ready")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Bluetooth Low Energy: Peripheral advertisement ready")
                    }
                }

                // Trusted Devices Section
                TrustManagementView(viewModel: viewModel)

                // Audit Log Section
                VStack(alignment: .leading, spacing: MacTheme.Spacing.xs) {
                    Text("SECURITY AUDIT LOG")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .tracking(1.0)
                        .foregroundStyle(.secondary)

                    MacCard {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(viewModel.recentAuditEvents, id: \.self) { event in
                                HStack(alignment: .top, spacing: MacTheme.Spacing.xs) {
                                    Image(systemName: "shield.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                        .padding(.top, 2)

                                    Text(event)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                // Footer
                HStack {
                    Spacer()
                    Text("Handshake v1.0 • Phase 1 Native Foundation • Zero Cloud Infrastructure")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .padding(MacTheme.Spacing.xl)
        }
        .frame(minWidth: 640, minHeight: 500)
        .sheet(isPresented: $viewModel.isPairingSheetPresented) {
            if let invitation = viewModel.activeInvitation {
                MacPairingView(invitation: invitation)
            }
        }
    }
}

