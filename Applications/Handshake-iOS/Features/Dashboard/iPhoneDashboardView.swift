import SwiftUI
import HandshakeCore

public struct iPhoneDashboardView: View {
    @ObservedObject public var viewModel: DashboardViewModel

    public init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HandshakeTheme.Spacing.lg) {
                    // MARK: - Header & Connection Pill
                    VStack(spacing: HandshakeTheme.Spacing.xs) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("HANDSHAKE")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .tracking(2.0)
                                    .foregroundStyle(.secondary)

                                Text("Local Control")
                                    .font(.largeTitle)
                                    .fontWeight(.bold)
                            }

                            Spacer()

                            Button {
                                viewModel.handleSecurityAuditTapped()
                            } label: {
                                Image(systemName: "shield.lefthalf.filled")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.primary)
                                    .padding(HandshakeTheme.Spacing.xs + 2)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .overlay(
                                        Circle()
                                            .stroke(HandshakeTheme.Colors.hairline, lineWidth: 1)
                                    )
                            }
                        }

                        // Connection Pill
                        HStack {
                            StatusPillView(state: viewModel.connectionState)
                            Spacer()
                            SecurityShieldBadge(status: viewModel.securityStatus)
                        }
                        .padding(.top, HandshakeTheme.Spacing.xs)
                    }
                    .padding(.horizontal, HandshakeTheme.Spacing.md)

                    // MARK: - Paired MacBook Identity Card
                    if let mac = viewModel.pairedMac {
                        HandshakeCard {
                            HStack(spacing: HandshakeTheme.Spacing.md) {
                                Image(systemName: mac.deviceType.sfSymbolName)
                                    .font(.system(size: 32, weight: .light))
                                    .foregroundStyle(.primary)
                                    .frame(width: 44, height: 44)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: HandshakeTheme.Radius.sm, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mac.displayName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)

                                    Text("\(mac.modelIdentifier) • \(mac.shortFingerprint)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Circle()
                                    .fill(HandshakeTheme.Colors.connected)
                                    .frame(width: 10, height: 10)
                            }
                        }
                        .padding(.horizontal, HandshakeTheme.Spacing.md)
                    }

                    // MARK: - Primary Control Actions (Large Buttons)
                    VStack(alignment: .leading, spacing: HandshakeTheme.Spacing.sm) {
                        Text("ACTIONS")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .tracking(1.0)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, HandshakeTheme.Spacing.md)

                        HandshakeActionButton(
                            title: "Lock Screen",
                            subtitle: "Locks display and requires Touch ID / password",
                            systemImage: "lock.fill",
                            style: .primary
                        ) {
                            viewModel.handleLockMacTapped()
                        }
                        .padding(.horizontal, HandshakeTheme.Spacing.md)

                        HandshakeActionButton(
                            title: "Sleep Mac",
                            subtitle: "Puts system into low-power sleep mode",
                            systemImage: "moon.fill",
                            style: .secondary
                        ) {
                            viewModel.handleSleepMacTapped()
                        }
                        .padding(.horizontal, HandshakeTheme.Spacing.md)
                    }

                    // MARK: - Secondary Actions
                    VStack(alignment: .leading, spacing: HandshakeTheme.Spacing.sm) {
                        Text("DEVICES")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .tracking(1.0)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, HandshakeTheme.Spacing.md)

                        HandshakeActionButton(
                            title: "Pair New Device",
                            subtitle: "Scan a QR code from another Mac or iPad",
                            systemImage: "qrcode.viewfinder",
                            style: .secondary
                        ) {
                            viewModel.handlePairNewDeviceTapped()
                        }
                        .padding(.horizontal, HandshakeTheme.Spacing.md)
                    }

                    // MARK: - Security Architecture Footnote
                    HStack(spacing: HandshakeTheme.Spacing.xs) {
                        Image(systemName: "checkmark.seal")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Zero Cloud • Direct Peer TLS & BLE Transport")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, HandshakeTheme.Spacing.md)
                    .padding(.bottom, HandshakeTheme.Spacing.lg)
                }
                .padding(.top, HandshakeTheme.Spacing.sm)
            }
            .sheet(isPresented: $viewModel.isPairingSheetPresented) {
                PairingScannerView()
            }
            .sheet(isPresented: $viewModel.isSecurityAuditPresented) {
                SecurityAuditView(status: viewModel.securityStatus)
            }
            .alert("Phase 1 Preview", isPresented: Binding(
                get: { viewModel.phase1NoticeMessage != nil },
                set: { if !$0 { viewModel.dismissNotice() } }
            )) {
                Button("OK", role: .cancel) {
                    viewModel.dismissNotice()
                }
            } message: {
                if let message = viewModel.phase1NoticeMessage {
                    Text(message)
                }
            }
        }
    }
}
