import DiskStewardCore
import SwiftUI

private enum ActivityTab: String, CaseIterable, Identifiable {
    case archiveRuns = "Archive Runs"
    case cleanupRuns = "Cleanup History"
    case verifiedRegistry = "Verified Archives"

    var id: String { rawValue }
}

/// Chronological history of archiving runs, confirmed cleanup operations, and verified SHA-256 archive records.
struct ActivityHistoryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: ActivityTab = .archiveRuns

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity & Verification History")
                    .font(.title2.weight(.bold))
                Spacer()
                Picker("View", selection: $selectedTab) {
                    ForEach(ActivityTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 380)
            }
            .padding(14)

            Divider()

            switch selectedTab {
            case .archiveRuns:
                archiveHistoryList
            case .cleanupRuns:
                cleanupHistoryList
            case .verifiedRegistry:
                verifiedArchivesList
            }
        }
    }

    private var archiveHistoryList: some View {
        Group {
            if appState.archiveRunHistory.isEmpty {
                emptyPlaceholder(icon: "archivebox", text: "No archive runs recorded yet.")
            } else {
                List(appState.archiveRunHistory) { report in
                    DisclosureGroup {
                        ForEach(report.outcomes.prefix(50)) { outcome in
                            HStack(spacing: 8) {
                                Text(outcome.kind.rawValue)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 120, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(outcome.sourcePath)
                                        .font(.caption2.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let dest = outcome.destinationPath {
                                        Text("→ \(dest)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.blue)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    if let detail = outcome.detail {
                                        Text(detail).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(report.jobName)
                                        .font(.subheadline.weight(.semibold))
                                    Text(report.trigger.displayName)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.07))
                                        .clipShape(Capsule())
                                }
                                Text("\(report.finishedAt.formatted(date: .abbreviated, time: .shortened)) • Copied: \(report.copiedCount + report.renamedCount) (\(ByteFormatting.string(from: report.bytesCopied))) • Duplicates: \(report.duplicateCount) • Unmatched: \(report.unmatchedCount) • Failed: \(report.failedCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(report.status.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(statusColor(report.status))
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var cleanupHistoryList: some View {
        Group {
            if appState.cleanupHistory.isEmpty {
                emptyPlaceholder(icon: "sparkles", text: "No confirmed cleanup operations recorded yet.")
            } else {
                List(appState.cleanupHistory) { run in
                    DisclosureGroup {
                        ForEach(run.itemResults) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).font(.caption.weight(.medium))
                                    Text(item.location).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    Text(item.detail).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.status.rawValue)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(item.didDelete ? .green : .orange)
                            }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(run.executedAt.formatted(date: .abbreviated, time: .shortened)) • \(run.deletionMode.displayName)")
                                    .font(.subheadline.weight(.semibold))
                                Text("Removed: \(run.succeededCount) (\(ByteFormatting.string(from: run.totalReclaimedBytes))) • Skipped (revalidation): \(run.skippedCount) • Failed: \(run.failedCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var verifiedArchivesList: some View {
        Group {
            if appState.verifiedArchives.isEmpty {
                emptyPlaceholder(icon: "checkmark.shield", text: "No verified SHA-256 archive copies tracked yet.")
            } else {
                List(appState.verifiedArchives) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(URL(fileURLWithPath: record.sourcePath).lastPathComponent)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(ByteFormatting.string(from: record.fileSize))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text("Original: \(record.sourcePath)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text("Archive:  \(record.destinationPath)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.blue)
                        Text("SHA-256:  \(record.sha256)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.green)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
    }

    private func emptyPlaceholder(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusColor(_ status: ArchiveRunStatus) -> Color {
        switch status {
        case .completed: return .green
        case .completedWithErrors, .deferredDestinationUnavailable: return .orange
        case .cancelled, .failed: return .red
        }
    }
}
