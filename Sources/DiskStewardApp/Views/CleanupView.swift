import DiskStewardCore
import SwiftUI

/// Presents automatically discovered cleanup proposals across archived originals, user files,
/// caches, Docker artifacts, and node_modules, requiring explicit user confirmation before any deletion (REQ-006, DEC-003).
struct CleanupView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedCategory: CleanupCategory? = nil
    @State private var showSettingsPopover: Bool = false

    private var visibleCategories: [CleanupCategory] {
        if let selectedCategory { return [selectedCategory] }
        return CleanupCategory.allCases
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Disk Cleanup Proposals")
                        .font(.title2.weight(.bold))
                    Text("Automatic discovery is read-only. Every deletion — including archived originals — requires your explicit confirmation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showSettingsPopover.toggle()
                } label: {
                    Label("Scan Scope", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showSettingsPopover) {
                    cleanupSettingsPopover
                }

                Button {
                    Task { await appState.refreshCleanupProposals() }
                } label: {
                    Label(appState.isScanningCleanup ? "Scanning…" : "Refresh Proposals", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isScanningCleanup || appState.isExecutingCleanup)
            }
            .padding(14)

            Divider()

            // Category filter pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    categoryChip(title: "All Categories", count: appState.cleanupCandidateCount, isSelected: selectedCategory == nil) {
                        selectedCategory = nil
                    }
                    ForEach(CleanupCategory.allCases) { cat in
                        let count = appState.cleanupProposal?.candidates(in: cat).count ?? 0
                        categoryChip(title: cat.displayName, count: count, isSelected: selectedCategory == cat) {
                            selectedCategory = cat
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))

            Divider()

            // Docker status / notes
            if let proposal = appState.cleanupProposal {
                if let dockerMsg = proposal.dockerStatusMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "shippingbox.circle")
                            .foregroundStyle(.secondary)
                        Text(dockerMsg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.03))
                    Divider()
                }

                ForEach(proposal.notes, id: \.self) { note in
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.orange)
                        Text(note)
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.08))
                    Divider()
                }
            }

            // Main proposals list
            if appState.isScanningCleanup && appState.cleanupProposal == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Inspecting archived originals, large user files, caches, Docker artifacts, and node_modules…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let proposal = appState.cleanupProposal, !proposal.candidates.isEmpty {
                List {
                    ForEach(visibleCategories) { category in
                        let items = proposal.candidates(in: category)
                        if !items.isEmpty {
                            Section {
                                ForEach(items) { candidate in
                                    candidateRow(candidate)
                                }
                            } header: {
                                HStack {
                                    Label(category.displayName, systemImage: category.systemImage)
                                        .font(.headline)
                                    Text("(\(items.count) • \(ByteFormatting.string(from: items.reduce(0) { $0 + $1.estimatedReclaimableBytes })))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Select All") {
                                        appState.selectAllCleanup(in: category)
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                    Button("None") {
                                        appState.deselectAllCleanup(in: category)
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 42))
                        .foregroundStyle(.green)
                    Text("No cleanup candidates found.")
                        .font(.headline)
                    Text("Archived originals, large files, caches, Docker artifacts, and node_modules will appear here when detected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // Bottom confirmation trigger bar
            HStack(spacing: 12) {
                if appState.isExecutingCleanup {
                    ProgressView().controlSize(.small)
                    Text("Revalidating and executing confirmed cleanup…")
                        .font(.subheadline)
                } else {
                    Text("Selected: \(appState.selectedCleanupIDs.count) item(s)")
                        .font(.subheadline.weight(.medium))
                    Text("• Estimated reclaimable: \(ByteFormatting.string(from: appState.selectedCleanupReclaimableBytes))")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.blue)
                }

                Spacer()

                if !appState.selectedCleanupIDs.isEmpty {
                    Button("Clear Selection") {
                        appState.selectedCleanupIDs.removeAll()
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    appState.showingCleanupConfirmation = true
                } label: {
                    Label("Review & Confirm Cleanup…", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(appState.selectedCleanupIDs.isEmpty || appState.isExecutingCleanup)
            }
            .padding(14)
            .background(.bar)
        }
        .sheet(isPresented: $appState.showingCleanupConfirmation) {
            CleanupConfirmationSheet()
                .environmentObject(appState)
        }
    }

    private func candidateRow(_ candidate: CleanupCandidate) -> some View {
        let isSelected = appState.selectedCleanupIDs.contains(candidate.id)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in appState.toggleCleanupCandidate(candidate.id) }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(candidate.title)
                        .font(.subheadline.weight(.medium))
                    if candidate.category == .archivedOriginals {
                        Label("SHA-256 Verified", systemImage: "checkmark.shield.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                Text(candidate.location)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(candidate.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormatting.string(from: candidate.estimatedReclaimableBytes))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                if let modified = candidate.lastModified {
                    Text(modified.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if !candidate.isDockerArtifact {
                Button("Reveal in Finder") {
                    appState.revealInFinder(path: candidate.location)
                }
            }
        }
    }

    private func categoryChip(title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption.weight(.medium))
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.05))
            .overlay(Capsule().stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var cleanupSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cleanup Discovery Settings")
                .font(.headline)

            Toggle("Inspect user & developer caches", isOn: $appState.configuration.includeCacheCleanup)
            Toggle("Inspect Docker images, containers, volumes & build cache", isOn: $appState.configuration.includeDockerCleanup)

            Picker("Large File Threshold", selection: $appState.configuration.cleanupLargeFileThresholdBytes) {
                Text("50 MB").tag(Int64(50_000_000))
                Text("100 MB").tag(Int64(100_000_000))
                Text("250 MB").tag(Int64(250_000_000))
                Text("500 MB").tag(Int64(500_000_000))
                Text("1 GB").tag(Int64(1_000_000_000))
            }

            Divider()

            HStack {
                Text("node_modules Search Folders")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Add…") {
                    if let folder = appState.chooseFolder(title: "Add Folder to Scan for node_modules") {
                        if !appState.configuration.nodeModulesSearchRoots.contains(folder) {
                            appState.configuration.nodeModulesSearchRoots.append(folder)
                            appState.persistState()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            ForEach(appState.configuration.nodeModulesSearchRoots, id: \.self) { root in
                HStack {
                    Text(root).font(.caption2.monospaced()).lineLimit(1)
                    Spacer()
                    Button(role: .destructive) {
                        appState.configuration.nodeModulesSearchRoots.removeAll { $0 == root }
                        appState.persistState()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                Spacer()
                Button("Apply & Rescan") {
                    appState.persistState()
                    showSettingsPopover = false
                    Task { await appState.refreshCleanupProposals() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 400)
    }
}
