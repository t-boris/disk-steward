import DiskStewardCore
import SwiftUI

/// Presents both rule-based recursive folder cleanup (DEC-011) and automatically discovered cleanup proposals
/// across archived originals, user files, caches, Docker artifacts, and node_modules, requiring explicit
/// confirmation before any deletion (REQ-006, DEC-003, DEC-006).
struct CleanupView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showSettingsPopover: Bool = false
    @State private var showIgnoredPopover: Bool = false
    @State private var showRuleBuilder: Bool = true
    @State private var extensionsInput: String = "zip"

    private let ageOptions: [(label: String, days: Int?)] = [
        ("Any age", nil),
        ("Older than 7 days", 7),
        ("Older than 30 days", 30),
        ("Older than 90 days", 90),
        ("Older than 1 year", 365)
    ]

    private let minSizeOptions: [(label: String, bytes: Int64)] = [
        ("Any size", 0),
        (">= 1 MB", 1_000_000),
        (">= 10 MB", 10_000_000),
        (">= 100 MB", 100_000_000)
    ]

    private var visibleCategories: [CleanupCategory] {
        if let selected = appState.cleanupActiveCategoryFilter {
            return [selected]
        }
        return CleanupCategory.allCases
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Disk Cleanup")
                        .font(.title2.weight(.bold))
                    Text("Target any folder with cleanup rules or review automatic proposals. Every deletion requires your confirmation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showRuleBuilder.toggle()
                    }
                } label: {
                    Label(showRuleBuilder ? "Hide Folder Rule" : "Folder Rule Cleanup", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)

                Button {
                    showIgnoredPopover.toggle()
                } label: {
                    Label("Ignored (\(appState.configuration.cleanupExclusions.count))", systemImage: "eye.slash")
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showIgnoredPopover) {
                    ignoredExclusionsPopover
                }

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

            // Rule-Based Folder Cleanup Panel (DEC-011)
            if showRuleBuilder {
                folderRuleCleanupPanel
                Divider()
            }

            // Category filter pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    categoryChip(
                        title: "All Categories",
                        count: appState.cleanupCandidateCount,
                        isSelected: appState.cleanupActiveCategoryFilter == nil
                    ) {
                        appState.cleanupActiveCategoryFilter = nil
                    }
                    ForEach(CleanupCategory.allCases) { cat in
                        let count = appState.cleanupProposal?.candidates(in: cat).count ?? 0
                        categoryChip(
                            title: cat.displayName,
                            count: count,
                            isSelected: appState.cleanupActiveCategoryFilter == cat
                        ) {
                            appState.cleanupActiveCategoryFilter = cat
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
            if (appState.isScanningCleanup && appState.cleanupProposal == nil) || appState.isEvaluatingCleanupRule {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(appState.isEvaluatingCleanupRule
                        ? "Scanning folder for files matching your cleanup rule…"
                        : "Inspecting archived originals, large user files, caches, Docker artifacts, and node_modules…")
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
                    Text("Use Folder Rule Cleanup above to target specific file types inside any folder, or refresh automatic proposals.")
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

                    Button {
                        appState.ignoreSelectedCleanupCandidates()
                    } label: {
                        Label("Ignore Selected", systemImage: "eye.slash")
                    }
                    .buttonStyle(.bordered)
                    .help("Persistently dismiss the selected proposals so they never reappear")
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
        .onAppear {
            syncExtensionsTextFromRule()
        }
        .onChange(of: appState.activeCleanupRule.id) { _, _ in
            syncExtensionsTextFromRule()
        }
        .sheet(isPresented: $appState.showingCleanupConfirmation) {
            CleanupConfirmationSheet()
                .environmentObject(appState)
        }
    }

    // MARK: - Rule-Based Folder Cleanup Panel (DEC-011)

    private var folderRuleCleanupPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Folder Rule Cleanup", systemImage: "wand.and.stars")
                    .font(.headline)
                Text("Pick a folder and match files recursively (e.g. code files, ZIP archives, videos, or custom extensions).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            // Row 1: Target Folder + Subfolders toggle + Quick Presets
            HStack(spacing: 8) {
                Text("Folder:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Target folder path", text: $appState.activeCleanupRule.folderPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                Button("Choose Folder…") {
                    if let picked = appState.chooseFolder(title: "Choose Folder to Clean by Rule", initialPath: appState.activeCleanupRule.folderPath) {
                        appState.activeCleanupRule.folderPath = picked
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Toggle("Include subfolders", isOn: $appState.activeCleanupRule.includeSubdirectories)
                    .font(.caption)
            }

            // Row 2: Quick one-click presets
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("Quick Rule:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    quickPresetButton("All ZIPs (.zip)", categories: [], exts: ["zip"])
                    quickPresetButton("All Archives", categories: [.archives], exts: [])
                    quickPresetButton("All Videos", categories: [.videos], exts: [])
                    quickPresetButton("All Code Files", categories: [.code], exts: [])
                    quickPresetButton("All Installers (.dmg/.pkg)", categories: [.installers], exts: ["dmg", "pkg"])
                    quickPresetButton("All Logs (.log)", categories: [], exts: ["log", "tmp"])
                }
            }

            // Row 3: File Categories multi-toggle
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("File Types:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(FileCategory.allCases) { cat in
                        let active = appState.activeCleanupRule.fileCategories.contains(cat)
                        Button {
                            if active {
                                appState.activeCleanupRule.fileCategories.removeAll { $0 == cat }
                            } else {
                                appState.activeCleanupRule.fileCategories.append(cat)
                            }
                        } label: {
                            Text(cat.displayName)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(active ? Color.accentColor.opacity(0.24) : Color.primary.opacity(0.06))
                                .overlay(Capsule().stroke(active ? Color.accentColor : Color.clear, lineWidth: 1))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Row 4: Extensions, Filename pattern, Age, Min Size, Actions
            HStack(spacing: 8) {
                TextField("Extensions (e.g. zip, mp4, py)", text: $extensionsInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 175)
                    .onChange(of: extensionsInput) { _, val in
                        appState.activeCleanupRule.customExtensions = val
                            .split(separator: ",")
                            .map {
                                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                                    .lowercased()
                            }
                            .filter { !$0.isEmpty }
                    }

                Picker("Name", selection: $appState.activeCleanupRule.fileNameMatchMode) {
                    ForEach(FileNameMatchMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 135)

                if appState.activeCleanupRule.fileNameMatchMode != .any {
                    TextField("Pattern (e.g. *.zip)", text: $appState.activeCleanupRule.fileNamePattern)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                }

                Picker("Age", selection: $appState.activeCleanupRule.olderThanDays) {
                    ForEach(ageOptions, id: \.label) { opt in
                        Text(opt.label).tag(opt.days)
                    }
                }
                .labelsHidden()
                .frame(width: 135)

                Picker("Size", selection: $appState.activeCleanupRule.minimumSizeBytes) {
                    ForEach(minSizeOptions, id: \.bytes) { opt in
                        Text(opt.label).tag(opt.bytes)
                    }
                }
                .labelsHidden()
                .frame(width: 105)

                Spacer()

                Button {
                    var toSave = appState.activeCleanupRule
                    toSave.id = UUID()
                    let folderName = URL(fileURLWithPath: toSave.folderPath).lastPathComponent
                    toSave.name = "\(toSave.summaryDescription) in \(folderName)"
                    appState.saveCleanupRule(toSave)
                } label: {
                    Label("Save Rule", systemImage: "bookmark")
                }
                .buttonStyle(.bordered)
                .disabled(!appState.activeCleanupRule.hasCriteria || appState.activeCleanupRule.folderPath.isEmpty)

                Button {
                    let rule = appState.activeCleanupRule
                    Task { await appState.runCleanupRule(rule) }
                } label: {
                    Label("Find Matching Files", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!appState.activeCleanupRule.hasCriteria || appState.activeCleanupRule.folderPath.isEmpty || appState.isEvaluatingCleanupRule)
            }

            // Saved rules strip
            if !appState.configuration.cleanupRules.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("Saved Rules:")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        ForEach(appState.configuration.cleanupRules) { saved in
                            HStack(spacing: 4) {
                                Button {
                                    appState.activeCleanupRule = saved
                                    syncExtensionsTextFromRule()
                                    Task { await appState.runCleanupRule(saved) }
                                } label: {
                                    Text(saved.name)
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    appState.deleteCleanupRule(id: saved.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.10))
                            .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func quickPresetButton(_ title: String, categories: [FileCategory], exts: [String]) -> some View {
        Button(title) {
            appState.activeCleanupRule.name = title
            appState.activeCleanupRule.fileCategories = categories
            appState.activeCleanupRule.customExtensions = exts
            appState.activeCleanupRule.fileNameMatchMode = .any
            appState.activeCleanupRule.fileNamePattern = ""
            extensionsInput = exts.joined(separator: ", ")
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    private func syncExtensionsTextFromRule() {
        extensionsInput = appState.activeCleanupRule.customExtensions.joined(separator: ", ")
    }

    // MARK: - Candidate Row & Helpers

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

            Button {
                appState.ignoreCleanupCandidate(candidate)
            } label: {
                Image(systemName: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss and permanently ignore this proposal")
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Ignore This Item") {
                appState.ignoreCleanupCandidate(candidate)
            }
            if !candidate.isDockerArtifact {
                let targetFolder = candidate.isDirectory
                    ? candidate.location
                    : URL(fileURLWithPath: candidate.location).deletingLastPathComponent().path
                let parentFolder = URL(fileURLWithPath: candidate.location).deletingLastPathComponent().path
                if candidate.isDirectory {
                    Button("Ignore Parent Folder (\(URL(fileURLWithPath: parentFolder).lastPathComponent))") {
                        appState.ignoreCleanupFolder(path: parentFolder)
                    }
                } else {
                    Button("Ignore Containing Folder (\(URL(fileURLWithPath: targetFolder).lastPathComponent))") {
                        appState.ignoreCleanupFolder(path: targetFolder)
                    }
                }
                Divider()
                Button("Reveal in Finder") {
                    appState.revealInFinder(path: candidate.location)
                }
            }
        }
    }

    private var ignoredExclusionsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ignored Cleanup Items & Folders")
                    .font(.headline)
                Spacer()
                if !appState.configuration.cleanupExclusions.isEmpty {
                    Button("Restore All") {
                        appState.restoreAllCleanupExclusions()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.blue)
                }
            }

            if appState.configuration.cleanupExclusions.isEmpty {
                Text("No items or folders are currently ignored. Click the eye-slash icon on any proposal or select items and click 'Ignore Selected' to hide them permanently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                List(appState.configuration.cleanupExclusions) { exclusion in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exclusion.label)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            if let path = exclusion.pathPrefix {
                                Text(path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else if let cid = exclusion.candidateID {
                                Text(cid)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Button("Restore") {
                            appState.restoreCleanupExclusion(id: exclusion.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
                .listStyle(.inset)
                .frame(height: 240)
            }

            HStack {
                Button {
                    if let folder = appState.chooseFolder(title: "Choose Folder to Permanently Exclude from Cleanup Proposals") {
                        appState.ignoreCleanupFolder(path: folder)
                    }
                } label: {
                    Label("Exclude Folder…", systemImage: "folder.badge.minus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                Button("Done") {
                    showIgnoredPopover = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 440)
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
