import AppKit
import DiskStewardCore
import SwiftUI

/// Persistent macOS menu bar popover providing instant disk health visibility and quick access to the full window (REQ-001, REQ-002).
struct MenuBarPopoverView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Label("Disk Steward", systemImage: "internaldrive.fill")
                    .font(.headline)
                Spacer()
                Text("v\(DiskStewardVersion.current)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    appState.refreshVolumes()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh disk capacity now")
            }

            Divider()

            // Disk capacity summary (Main + Connected Additional + Unavailable disks)
            VStack(alignment: .leading, spacing: 8) {
                Text("Disks")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if appState.volumes.isEmpty {
                    Text("No volumes detected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.volumes) { volume in
                        Button {
                            openMainWindow()
                            if volume.isConnected {
                                appState.exploreVolume(volume)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: volume.isMainDisk ? "internaldrive" : "externaldrive")
                                        .foregroundStyle(volume.isConnected ? .primary : .secondary)
                                    Text(volume.name)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Spacer()
                                    if volume.isConnected {
                                        Text("\(ByteFormatting.string(from: volume.freeBytes)) free")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(UsageTint.color(forFraction: volume.usedFraction))
                                    } else {
                                        Text("Unavailable")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }

                                if volume.isConnected {
                                    ProgressView(value: volume.usedFraction)
                                        .tint(UsageTint.color(forFraction: volume.usedFraction))
                                    HStack {
                                        Text("Used: \(ByteFormatting.string(from: volume.usedBytes))")
                                        Spacer()
                                        Text("Total: \(ByteFormatting.string(from: volume.totalBytes))")
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                } else {
                                    Text("Disconnected • Last seen \(volume.lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(8)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Unresolved deferred archive runs (kept visible in menu bar independently of system notifications, R-001)
            if !appState.pendingArchiveRuns.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(appState.pendingArchiveRuns.count) Pending Archive Run(s)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    ForEach(appState.pendingArchiveRuns) { pending in
                        Text("\(pending.jobName) waiting for \(pending.requiredVolumeRoots.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Active archiving progress
            if appState.isArchiving {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Archiving in progress…")
                            .font(.caption.weight(.medium))
                        if let prog = appState.activeArchiveProgress {
                            Text("\(prog.completedItems)/\(prog.totalItems): \(prog.currentFileName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Cleanup opportunities summary (read-only until user confirms!)
            if appState.cleanupCandidateCount > 0 {
                Button {
                    appState.selectedSection = .cleanup
                    openMainWindow()
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(appState.cleanupCandidateCount) Cleanup Proposal(s) Ready")
                                .font(.caption.weight(.semibold))
                            Text("Up to \(ByteFormatting.string(from: appState.totalProposedReclaimableBytes)) reclaimable • Confirmation required")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(Color.blue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Quick Actions
            HStack(spacing: 8) {
                Button {
                    openMainWindow()
                } label: {
                    Label("Open Disk Steward", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if let firstJob = appState.configuration.archiveJobs.first, !appState.isArchiving {
                    Button {
                        Task {
                            await appState.runArchiveJob(firstJob, trigger: .onDemand)
                        }
                    } label: {
                        Label("Archive", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .help("Run '\(firstJob.name)' now")
                }
            }

            HStack {
                if let lastRefresh = appState.lastVolumeRefresh {
                    Text("Updated \(lastRefresh.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit Disk Steward") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
