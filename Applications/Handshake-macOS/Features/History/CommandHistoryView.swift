import SwiftUI
import HandshakeCore

/// Read-only audit screen displaying command execution logs from local SQLite storage.
/// Shows: Time, Device, Command, Status, Result.
/// Enforces Zero-Cloud guarantee: all data is queried strictly from local disk.
public struct CommandHistoryView: View {
    @ObservedObject public var viewModel: MacDashboardViewModel
    @State private var filter: CommandStatusFilter = .all
    @State private var searchText: String = ""
    @Environment(\.dismiss) private var dismiss

    public enum CommandStatusFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case executed = "Executed"
        case failed = "Failed"
        case rejected = "Rejected"

        public var id: String { rawValue }
    }

    public init(viewModel: MacDashboardViewModel) {
        self.viewModel = viewModel
    }

    private var filteredLogs: [CommandLogRecord] {
        viewModel.commandLogs.filter { record in
            // Status filter
            switch filter {
            case .all:
                break
            case .executed:
                guard record.status.lowercased() == "executed" else { return false }
            case .failed:
                guard record.status.lowercased() == "failed" else { return false }
            case .rejected:
                guard record.status.lowercased() == "rejected" else { return false }
            }

            // Search text
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                let matchesCommand = record.commandType.lowercased().contains(query)
                let matchesDevice = (record.peerDeviceName ?? "").lowercased().contains(query) || record.peerDeviceId.lowercased().contains(query)
                let matchesReqId = record.requestId.lowercased().contains(query)
                let matchesResult = (record.resultCode ?? "").lowercased().contains(query) || (record.errorMessage ?? "").lowercased().contains(query)
                return matchesCommand || matchesDevice || matchesReqId || matchesResult
            }

            return true
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: MacTheme.Spacing.xs) {
                        Image(systemName: "cylinder.split.1x2.fill")
                            .foregroundStyle(MacTheme.Colors.accent)
                        Text("AUDIT DATABASE")
                            .font(.caption)
                            .fontWeight(.bold)
                            .tracking(2.0)
                            .foregroundStyle(.secondary)
                    }

                    Text("Command Execution History")
                        .font(.title2)
                        .fontWeight(.bold)
                }

                Spacer()

                // Refresh Button
                Button(action: {
                    viewModel.refreshCommandLogs()
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                // Close Button
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(MacTheme.Spacing.lg)
            .background(.ultraThinMaterial)

            Divider()

            // Filters & Metrics Bar
            HStack(spacing: MacTheme.Spacing.md) {
                // Filter Picker
                Picker("Filter", selection: $filter) {
                    ForEach(CommandStatusFilter.allCases) { filterCase in
                        Text(filterCase.rawValue).tag(filterCase)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search device, command, or request ID...", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(MacTheme.Radius.sm)
                .overlay(
                    RoundedRectangle(cornerRadius: MacTheme.Radius.sm)
                        .stroke(MacTheme.Colors.hairline, lineWidth: 1)
                )

                Spacer()

                // Total count badge
                Text("\(filteredLogs.count) of \(viewModel.commandLogs.count) events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, MacTheme.Spacing.lg)
            .padding(.vertical, MacTheme.Spacing.sm)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Table Header & Rows
            if filteredLogs.isEmpty {
                VStack(spacing: MacTheme.Spacing.md) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)

                    Text("No Command History Found")
                        .font(.headline)

                    Text(viewModel.commandLogs.isEmpty
                         ? "Commands received from paired devices will be logged securely to ~/Library/Application Support/Handshake/handshake.sqlite."
                         : "No commands match the current filter criteria.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // Header row
                    HStack(spacing: MacTheme.Spacing.md) {
                        Text("TIME (UTC)")
                            .frame(width: 140, alignment: .leading)
                        Text("DEVICE")
                            .frame(width: 140, alignment: .leading)
                        Text("COMMAND")
                            .frame(width: 120, alignment: .leading)
                        Text("STATUS")
                            .frame(width: 100, alignment: .leading)
                        Text("RESULT / ERROR")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)

                    Divider()

                    ForEach(filteredLogs, id: \.requestId) { record in
                        HStack(spacing: MacTheme.Spacing.md) {
                            // Time
                            VStack(alignment: .leading, spacing: 2) {
                                Text(formatTime(record.receivedAt))
                                    .font(.system(.body, design: .monospaced))
                                    .fontWeight(.medium)
                                Text(formatDate(record.receivedAt))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 140, alignment: .leading)

                            // Device
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.peerDeviceName ?? "Unknown")
                                    .font(.body)
                                    .fontWeight(.semibold)
                                Text(String(record.peerDeviceId.prefix(12)) + "...")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 140, alignment: .leading)

                            // Command
                            HStack(spacing: 4) {
                                Image(systemName: iconForCommand(record.commandType))
                                    .font(.caption)
                                Text(record.commandType)
                                    .font(.system(.caption, design: .monospaced))
                                    .fontWeight(.bold)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(MacTheme.Radius.sm)
                            .frame(width: 120, alignment: .leading)

                            // Status Pill
                            StatusPill(status: record.status)
                                .frame(width: 100, alignment: .leading)

                            // Result / Details
                            VStack(alignment: .leading, spacing: 2) {
                                if let error = record.errorMessage, !error.isEmpty {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                } else if let code = record.resultCode {
                                    Text(code)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(record.status.lowercased() == "executed" ? .green : .secondary)
                                } else {
                                    Text("—")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Text("ID: \(record.requestId.prefix(8))...")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            // Footer path & storage metadata
            HStack {
                Image(systemName: "lock.shield.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("~/Library/Application Support/Handshake/handshake.sqlite • Local SQLite WAL Mode • Parameterized SQL")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Version 1.0")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, MacTheme.Spacing.lg)
            .padding(.vertical, MacTheme.Spacing.xs)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 780, minHeight: 480)
        .onAppear {
            viewModel.refreshCommandLogs()
        }
    }

    private func formatTime(_ isoString: String) -> String {
        if let date = DatabaseManager.date(from: isoString) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            formatter.timeZone = .current
            return formatter.string(from: date)
        }
        return isoString
    }

    private func formatDate(_ isoString: String) -> String {
        if let date = DatabaseManager.date(from: isoString) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = .current
            return formatter.string(from: date)
        }
        return ""
    }

    private func iconForCommand(_ command: String) -> String {
        switch command.uppercased() {
        case "LOCK_MAC", "LOCKSCREEN": return "lock.fill"
        case "SLEEP_MAC", "SLEEP": return "moon.fill"
        case "PING": return "waveform"
        case "STATUS": return "info.circle"
        default: return "terminal.fill"
        }
    }
}

private struct StatusPill: View {
    let status: String

    var color: Color {
        switch status.lowercased() {
        case "executed": return .green
        case "failed": return .red
        case "rejected": return .orange
        case "received", "executing": return .blue
        default: return .secondary
        }
    }

    var body: some View {
        Text(status.uppercased())
            .font(.system(.caption2, design: .monospaced))
            .fontWeight(.bold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15))
            .cornerRadius(MacTheme.Radius.sm)
    }
}
