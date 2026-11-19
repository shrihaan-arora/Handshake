import SwiftUI
import CoreBluetooth
import HandshakeCore

public struct BLEPairingView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject public var viewModel: DashboardViewModel

    public init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: HandshakeTheme.Spacing.lg) {
                        // Header
                        headerSection

                        // Dynamic state section
                        if let sasCode = viewModel.bleDerivedSAS {
                            sasVerificationSection(sasCode: sasCode)
                        } else if let err = viewModel.blePairingError {
                            errorSection(err: err)
                        } else if viewModel.selectedBLEHost != nil {
                            pairingProgressSection
                        } else {
                            discoveredHostsSection
                        }
                    }
                    .padding(.horizontal, HandshakeTheme.Spacing.md)
                    .padding(.top, HandshakeTheme.Spacing.md)
                    .padding(.bottom, HandshakeTheme.Spacing.xl)
                }
            }
            .navigationTitle("Pair via Bluetooth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        viewModel.dismissBLEPairing()
                        dismiss()
                    }
                }

                if viewModel.selectedBLEHost == nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            viewModel.startBLEDiscovery()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(viewModel.isScanningBLE)
                        .accessibilityLabel("Refresh nearby Macs scan")
                    }
                }
            }
            .onAppear {
                if viewModel.discoveredBLEHosts.isEmpty {
                    viewModel.startBLEDiscovery()
                }
            }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: HandshakeTheme.Spacing.xs) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .padding(.bottom, HandshakeTheme.Spacing.xs)

            Text("Bluetooth LE Direct Pairing")
                .font(.title2)
                .fontWeight(.bold)

            Text("Initial pairing requires the Mac QR invitation. Bluetooth is used automatically when the invitation's TCP endpoint is unreachable.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Discovered Hosts List

    private var discoveredHostsSection: some View {
        VStack(alignment: .leading, spacing: HandshakeTheme.Spacing.sm) {
            HStack {
                Text("NEARBY MAC COMPANIONS")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .tracking(1.0)
                    .foregroundStyle(.secondary)

                Spacer()

                if viewModel.isScanningBLE {
                    HStack(spacing: 6) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                        Text("Scanning...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if viewModel.discoveredBLEHosts.isEmpty {
                HandshakeCard {
                    VStack(spacing: HandshakeTheme.Spacing.sm) {
                        Image(systemName: "laptopcomputer.slash")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)

                        Text("No Nearby Macs Found")
                            .font(.headline)

                        Text("Make sure Handshake is open on your Mac and 'Pair iPhone' is tapped to advertise.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button("Scan Again") {
                            viewModel.startBLEDiscovery()
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, HandshakeTheme.Spacing.xs)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HandshakeTheme.Spacing.sm)
                }
            } else {
                ForEach(viewModel.discoveredBLEHosts) { host in
                    HandshakeCard {
                        HStack(spacing: HandshakeTheme.Spacing.md) {
                            Image(systemName: "laptopcomputer")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.primary)
                                .frame(width: 44, height: 44)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: HandshakeTheme.Radius.sm))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                HStack(spacing: 4) {
                                    Image(systemName: signalIcon(for: host.rssi))
                                        .font(.caption2)
                                        .foregroundStyle(signalColor(for: host.rssi))

                                    Text("\(host.rssi) dBm • Ready to pair")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Button("Pair") {
                                viewModel.pairWithSelectedBLEHost(host)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Pairing Progress Section

    private var pairingProgressSection: some View {
        HandshakeCard {
            VStack(spacing: HandshakeTheme.Spacing.md) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.2)
                    .tint(.blue)

                VStack(spacing: 4) {
                    Text(viewModel.blePairingStage.stageLabel)
                        .font(.headline)

                    if let host = viewModel.selectedBLEHost {
                        Text("Exchanging ephemeral P-256 keys with \(host.name)...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HandshakeTheme.Spacing.md)
        }
    }

    // MARK: - SAS Verification Section

    private func sasVerificationSection(sasCode: String) -> some View {
        VStack(spacing: HandshakeTheme.Spacing.md) {
            HandshakeCard {
                VStack(spacing: HandshakeTheme.Spacing.sm) {
                    Text("VERIFICATION CODE (SAS)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .tracking(1.5)
                        .foregroundStyle(.secondary)

                    Text(sasCode)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .tracking(3.0)

                    Text("Compare this 6-digit code with the code shown on your Mac. Tap Approve if both match.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, HandshakeTheme.Spacing.sm)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, HandshakeTheme.Spacing.sm)
            }

            // Bilateral Decision Buttons
            HStack(spacing: HandshakeTheme.Spacing.md) {
                Button(role: .cancel) {
                    viewModel.rejectBLEPairing()
                } label: {
                    Text("Reject")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.large)

                Button {
                    viewModel.approveBLEPairing()
                } label: {
                    Text("Approve & Pair")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Error Section

    private func errorSection(err: String) -> some View {
        VStack(spacing: HandshakeTheme.Spacing.md) {
            HandshakeCard {
                VStack(spacing: HandshakeTheme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.red)

                    Text("Pairing Failed")
                        .font(.headline)

                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, HandshakeTheme.Spacing.sm)
            }

            Button("Try Again") {
                viewModel.startBLEDiscovery()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Helpers

    private func signalIcon(for rssi: Int) -> String {
        if rssi >= -60 { return "wifi" }
        if rssi >= -75 { return "wifi" }
        return "wifi.exclamationmark"
    }

    private func signalColor(for rssi: Int) -> Color {
        if rssi >= -60 { return .green }
        if rssi >= -75 { return .orange }
        return .red
    }
}
