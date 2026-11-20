import DiskStewardCore
import SwiftUI

/// Live capacity monitoring dashboard for main and additional disks (REQ-002, plan I-2).
struct DiskOverviewView: View {
    @EnvironmentObject private var appState: AppState

    private let refreshOptions: [(label: String, seconds: TimeInterval)] = [
        ("10 seconds", 10),
        ("30 seconds", 30),
        ("1 minute", 60),
        ("5 minutes", 300)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Disk Health Overview")
                            .font(.largeTitle.weight(.bold))
                        if let updated = appState.lastVolumeRefresh {
                            Text("Monitoring main disk and connected storage volumes • Last refreshed \(updated.formatted(date: .omitted, time: .standard))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Picker("Refresh", selection: Binding(
                        get: { appState.configuration.volumeRefreshIntervalSeconds },
                        set: { appState.updateVolumeRefreshInterval($0) }
                    )) {
                        ForEach(refreshOptions, id: \.seconds) { opt in
                            Text(opt.label).tag(opt.seconds)
                        }
                    }
                    .frame(width: 170)

                    Button {
                        appState.refreshVolumes()
                    } label: {
                        Label("Refresh Now", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

                // Quick KPI Strip
                HStack(spacing: 14) {
                    summaryKPI(
                        title: "Connected Disks",
                        value: "\(appState.connectedVolumes.count)",
                        subtitle: appState.disconnectedVolumes.isEmpty ? "All tracked disks online" : "\(appState.disconnectedVolumes.count) unavailable",
                        icon: "internaldrive",
                        tint: .accentColor
                    )
                    summaryKPI(
                        title: "Archive Jobs",
                        value: "\(appState.configuration.archiveJobs.count)",
                        subtitle: appState.pendingArchiveRuns.isEmpty
                            ? "\(appState.verifiedArchives.count) verified archived file(s)"
                            : "\(appState.pendingArchiveRuns.count) pending reconnect",
                        icon: "archivebox",
                        tint: appState.pendingArchiveRuns.isEmpty ? .green : .orange
                    )
                    summaryKPI(
                        title: "Proposed Cleanup",
                        value: ByteFormatting.string(from: appState.totalProposedReclaimableBytes),
                        subtitle: "\(appState.cleanupCandidateCount) item(s) awaiting confirmation",
                        icon: "sparkles",
                        tint: .blue
                    )
                }

                // Pending deferred runs banner
                if !appState.pendingArchiveRuns.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Deferred Scheduled Archive Runs Waiting for Disk Connection", systemImage: "externaldrive.badge.timemachine")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        ForEach(appState.pendingArchiveRuns) { pending in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pending.jobName)
                                        .font(.subheadline.weight(.semibold))
                                    Text("Waiting for: \(pending.requiredVolumeRoots.joined(separator: ", ")) • Missed runs consolidated: \(pending.missedRunCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Open Archiving") {
                                    appState.selectedSection = .archiving
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(14)
                    .background(Color.orange.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // Volume Cards
                VStack(alignment: .leading, spacing: 12) {
                    Text("Monitored Volumes")
                        .font(.title3.weight(.semibold))

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14)], spacing: 14) {
                        ForEach(appState.volumes) { volume in
                            volumeCard(volume)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func summaryKPI(title: String, value: String, subtitle: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func volumeCard(_ volume: DiskVolume) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: volume.isMainDisk ? "internaldrive.fill" : "externaldrive.fill")
                    .font(.title2)
                    .foregroundStyle(volume.isConnected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.name)
                        .font(.headline)
                    Text("\(volume.kindLabel) • \(volume.mountPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(volume.statusLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(volume.isConnected ? Color.green.opacity(0.16) : Color.orange.opacity(0.18))
                    .foregroundStyle(volume.isConnected ? .green : .orange)
                    .clipShape(Capsule())
            }

            if volume.isConnected {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: volume.usedFraction)
                        .tint(UsageTint.color(forFraction: volume.usedFraction))

                    HStack {
                        metricColumn(label: "Total", value: ByteFormatting.string(from: volume.totalBytes))
                        Spacer()
                        metricColumn(label: "Used (\(ByteFormatting.percentString(volume.usedFraction)))", value: ByteFormatting.string(from: volume.usedBytes))
                        Spacer()
                        metricColumn(label: "Free", value: ByteFormatting.string(from: volume.freeBytes))
                    }

                    if volume.purgeableBytes > 100_000_000 {
                        Text("Includes \(ByteFormatting.string(from: volume.purgeableBytes)) additional macOS purgeable space")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button {
                        appState.exploreVolume(volume)
                    } label: {
                        Label("Explore Storage", systemImage: "square.grid.2x2")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        appState.revealInFinder(path: volume.mountPath)
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Disk is currently disconnected. Capacity metrics are unavailable until reconnected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Last observed: \(volume.lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(volume.isConnected ? Color.primary.opacity(0.08) : Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    private func metricColumn(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }
}
