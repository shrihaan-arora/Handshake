import SwiftUI
import HandshakeCore

public struct TrustManagementView: View {
    @ObservedObject public var viewModel: MacDashboardViewModel
    @State private var deviceToRevoke: TrustRecord?

    public init(viewModel: MacDashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MacTheme.Spacing.sm) {
            HStack {
                Text("TRUSTED DEVICES")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .tracking(1.0)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    viewModel.startPairingFlow()
                } label: {
                    Label("Pair iPhone", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if viewModel.trustedDevices.isEmpty {
                MacCard {
                    HStack {
                        Image(systemName: "iphone.slash")
                            .font(.title2)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("No Paired Devices")
                                .font(.headline)
                            Text("Pair an iPhone to enable secure local control.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, MacTheme.Spacing.xs)
                }
            } else {
                VStack(spacing: MacTheme.Spacing.xs) {
                    ForEach(Array(viewModel.trustedDevices.enumerated()), id: \.element.id) { index, record in
                        MacCard {
                            HStack(spacing: MacTheme.Spacing.md) {
                                Image(systemName: record.peer.deviceType.sfSymbolName)
                                    .font(.title3)
                                    .foregroundStyle(.primary)
                                    .frame(width: 32, height: 32)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: MacTheme.Radius.sm))

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(record.peer.displayName)
                                            .font(.headline)

                                        if record.isRevoked {
                                            Text("REVOKED")
                                                .font(.caption2)
                                                .fontWeight(.bold)
                                                .foregroundStyle(.red)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.red.opacity(0.1), in: Capsule())
                                        } else {
                                            Text("TRUSTED")
                                                .font(.caption2)
                                                .fontWeight(.bold)
                                                .foregroundStyle(.green)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.green.opacity(0.1), in: Capsule())
                                        }
                                    }

                                    Text("\(record.peer.modelIdentifier) • Fingerprint: \(record.peer.shortFingerprint)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if !record.isRevoked {
                                    Button("Revoke") {
                                        deviceToRevoke = record
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(.red)
                                }
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Revoke Device Trust?",
            isPresented: Binding(
                get: { deviceToRevoke != nil },
                set: { if !$0 { deviceToRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke Trust", role: .destructive) {
                if let target = deviceToRevoke,
                   let index = viewModel.trustedDevices.firstIndex(where: { $0.id == target.id }) {
                    viewModel.revokeDevice(at: index)
                }
                deviceToRevoke = nil
            }
            Button("Cancel", role: .cancel) {
                deviceToRevoke = nil
            }
        } message: {
            if let target = deviceToRevoke {
                Text("Are you sure you want to revoke trust for '\(target.peer.displayName)'? It will immediately lose access to control this Mac.")
            }
        }
    }
}
