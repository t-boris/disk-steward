import DiskStewardCore
import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $appState.selectedSection) {
                Section("Workspace") {
                    ForEach(AppSection.allCases) { section in
                        HStack {
                            Label(section.title, systemImage: section.systemImage)
                            Spacer()
                            if section == .archiving && !appState.pendingArchiveRuns.isEmpty {
                                Text("\(appState.pendingArchiveRuns.count)")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.2))
                                    .foregroundStyle(.orange)
                                    .clipShape(Capsule())
                            } else if section == .cleanup && appState.cleanupCandidateCount > 0 {
                                Text("\(appState.cleanupCandidateCount)")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.18))
                                    .foregroundStyle(.blue)
                                    .clipShape(Capsule())
                            }
                        }
                        .tag(section)
                    }
                }

                Section("Monitored Disks") {
                    ForEach(appState.volumes) { volume in
                        Button {
                            if volume.isConnected {
                                appState.exploreVolume(volume)
                            } else {
                                appState.selectedSection = .overview
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(volume.isConnected ? Color.green : Color.orange)
                                        .frame(width: 7, height: 7)
                                    Text(volume.name)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Spacer()
                                    if volume.isConnected {
                                        Text(ByteFormatting.string(from: volume.freeBytes))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("Offline")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                if volume.isConnected {
                                    ProgressView(value: volume.usedFraction)
                                        .tint(UsageTint.color(forFraction: volume.usedFraction))
                                        .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text(DiskStewardVersion.displayString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if let banner = appState.statusBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                        Text(banner)
                            .font(.caption)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            appState.statusBanner = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.08))
                    Divider()
                }

                Group {
                    switch appState.selectedSection {
                    case .overview:
                        DiskOverviewView()
                    case .explorer:
                        StorageExplorerView()
                    case .archiving:
                        ArchivingView()
                    case .cleanup:
                        CleanupView()
                    case .activity:
                        ActivityHistoryView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
