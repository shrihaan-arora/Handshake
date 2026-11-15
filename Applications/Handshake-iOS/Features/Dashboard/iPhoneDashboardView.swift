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
                            .accessibilityLabel("Security Posture Audit")
                            .accessibilityHint("Opens detailed cryptographic and transport security assessment")
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
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Paired device: \(mac.displayName), \(mac.modelIdentifier), fingerprint \(mac.shortFingerprint)")
                        .padding(.horizontal, HandshakeTheme.Spacing.md)
                    } else {
                        HandshakeCard {
                            HStack(spacing: HandshakeTheme.Spacing.md) {
                                Image(systemName: "macbook.and.iphone")
                                    .font(.system(size: 28, weight: .light))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, height: 44)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: HandshakeTheme.Radius.sm, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("No Paired MacBook")
                                        .font(.headline)
                                        .foregroundStyle(.primary)

                                    Text("Pair with your Mac to enable direct local control.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("No paired MacBook. Pair with your Mac to enable direct local control.")
                        .padding(.horizontal, HandshakeTheme.Spacing.md)
                    }

                    // MARK: - Command Execution Progress HUD
                    if viewModel.commandStage != .idle {
                        commandStageHUD
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
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
                            style: .primary,
                            isEnabled: viewModel.pairedMac != nil && !viewModel.isExecutingCommand,
                            isLoading: viewModel.isExecutingCommand && viewModel.commandStage.command == .lockScreen,
                            statusBadge: viewModel.commandStage.command == .lockScreen ? viewModel.commandStage.stageLabel : nil
                        ) {
                            viewModel.handleLockMacTapped()
                        }
                        .padding(.horizontal, HandshakeTheme.Spacing.md)

                        HandshakeActionButton(
                            title: "Sleep Mac",
                            subtitle: "Puts system into low-power sleep mode",
                            systemImage: "moon.fill",
                            style: .secondary,
                            isEnabled: viewModel.pairedMac != nil && !viewModel.isExecutingCommand,
                            isLoading: viewModel.isExecutingCommand && viewModel.commandStage.command == .sleep,
                            statusBadge: viewModel.commandStage.command == .sleep ? viewModel.commandStage.stageLabel : nil
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
                        Text("Zero Cloud • Direct Local Wi-Fi & BLE Transport")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, HandshakeTheme.Spacing.md)
                    .padding(.bottom, HandshakeTheme.Spacing.lg)
                }
                .padding(.top, HandshakeTheme.Spacing.sm)
            }
            .sheet(isPresented: $viewModel.isPairingSheetPresented) {
                PairingScannerView(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isSecurityAuditPresented) {
                SecurityAuditView(status: viewModel.securityStatus)
            }
            .alert(viewModel.alertTitle, isPresented: Binding(
                get: { viewModel.alertMessage != nil },
                set: { if !$0 { viewModel.dismissNotice() } }
            )) {
                Button("OK", role: .cancel) {
                    viewModel.dismissNotice()
                }
            } message: {
                if let message = viewModel.alertMessage {
                    Text(message)
                }
            }
        }
    }

    // MARK: - Command Execution Stage HUD Banner

    private var commandStageHUD: some View {
        HandshakeCard {
            HStack(spacing: HandshakeTheme.Spacing.md) {
                switch viewModel.commandStage {
                case .sending(let cmd):
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.1)
                        .tint(.blue)
                        .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Sending")
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundStyle(.blue)

                            Text("• \(cmd.displayName)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text("Transmitting authenticated wire envelope...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .executing(let cmd):
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.orange)
                        .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Executing")
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundStyle(.orange)

                            Text("• \(cmd.displayName)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text("Invoking verified system action on Mac...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .completed(let cmd, let details):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.green)
                        .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Completed")
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundStyle(.green)

                            Text("• \(cmd.displayName)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .failed(let cmd, let reason):
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Failed")
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundStyle(.red)

                            Text("• \(cmd.displayName)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                case .idle:
                    EmptyView()
                }

                Spacer()
            }
            .padding(.vertical, HandshakeTheme.Spacing.xs)
        }
    }
}
