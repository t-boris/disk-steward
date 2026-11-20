import AppKit
import DiskStewardCore
import SwiftUI

private enum InspectorTab: String, CaseIterable, Identifiable {
    case largest = "Largest Items"
    case byType = "By File Type"
    case byDate = "By Date"

    var id: String { rawValue }
}

/// Instant, FSEvents-cached visual storage explorer (REQ-003, REQ-004, DEC-010, DEC-011, DEC-012).
/// - All breakdowns, rankings, and filters run off the Main Thread via precomputed ExplorerSnapshots.
/// - Hover state stays strictly local so moving the mouse triggers ZERO AppState or tree recomputation.
struct StorageExplorerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var inspectorTab: InspectorTab = .largest
    @State private var showIssuesPopover: Bool = false
    @State private var customExtInput: String = ""
    @State private var hoveredNode: StorageNode?

    private let minSizeOptions: [(label: String, bytes: Int64)] = [
        ("Any Size", 0),
        (">= 10 MB", 10_000_000),
        (">= 100 MB", 100_000_000),
        (">= 500 MB", 500_000_000),
        (">= 1 GB", 1_000_000_000)
    ]

    var body: some View {
        VStack(spacing: 0) {
            topControlBar
            Divider()
            filterBar
            Divider()

            if appState.isScanning {
                scanningProgressBanner
                Divider()
            } else if appState.isRefreshingBackgroundCache {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Refreshing updated files in background…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.07))
                Divider()
            } else if let result = appState.scanResult, !result.isComplete {
                incompleteScanBanner(result)
                Divider()
            }

            if let snapshot = appState.explorerSnapshot, !snapshot.isEmptyDueToFilter {
                breadcrumbBar(snapshot: snapshot)
                Divider()

                HSplitView {
                    // Left: Single-Level Structural Treemap + Local Hover Strip (ZERO AppState mutation on hover!)
                    VStack(spacing: 10) {
                        TreemapView(
                            scopeKey: snapshot.scopePath,
                            scopeTotalBytes: snapshot.scopeAllocatedBytes,
                            children: snapshot.directChildren,
                            selectedNodeID: appState.selectedNodeID,
                            onHover: { hoveredNode = $0 },
                            onSelect: { appState.selectedNodeID = $0.id },
                            onDrillDown: {
                                hoveredNode = nil
                                appState.drillDown(to: $0)
                            },
                            onRevealInFinder: { appState.revealInFinder(path: $0) },
                            onCleanFolderByRule: { appState.openFolderCleanupFromExplorer(folderPath: $0) }
                        )
                        .frame(minHeight: 340)

                        hoverStatusBar(snapshot: snapshot)
                    }
                    .padding(14)
                    .frame(minWidth: 440)

                    // Right: Precomputed Largest Items / By File Type / By Date Inspector
                    VStack(spacing: 10) {
                        HStack {
                            Picker("Inspector", selection: $inspectorTab) {
                                ForEach(InspectorTab.allCases) { tab in
                                    Text(tab.rawValue).tag(tab)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)

                            if appState.isComputingSnapshot {
                                ProgressView().controlSize(.small)
                            }
                        }

                        switch inspectorTab {
                        case .largest:
                            largestItemsList(snapshot: snapshot)
                        case .byType:
                            categoryBreakdownView(snapshot: snapshot)
                        case .byDate:
                            dateBreakdownView(snapshot: snapshot)
                        }
                    }
                    .padding(14)
                    .frame(minWidth: 320, idealWidth: 380)
                }
            } else if let snapshot = appState.explorerSnapshot, snapshot.isEmptyDueToFilter {
                VStack(spacing: 12) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No files match the active filters in this folder.")
                        .font(.headline)
                    Button("Reset Filters") {
                        customExtInput = ""
                        appState.resetFilters()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyExplorerState
            }
        }
        .onAppear {
            appState.loadCachedExplorerIfAvailable()
        }
        .onChange(of: appState.storageFilter) { _, _ in
            appState.refreshExplorerSnapshot()
        }
    }

    // MARK: - Controls

    private var topControlBar: some View {
        HStack(spacing: 10) {
            Menu {
                Section("Connected Disks") {
                    ForEach(appState.connectedVolumes) { volume in
                        Button {
                            hoveredNode = nil
                            appState.openInExplorer(path: volume.mountPath, forceRescan: false)
                        } label: {
                            Label("\(volume.name) (\(volume.mountPath))", systemImage: volume.isMainDisk ? "internaldrive" : "externaldrive")
                        }
                    }
                }
                Section("Common Folders") {
                    ForEach(commonShortcutFolders(), id: \.path) { folder in
                        Button {
                            hoveredNode = nil
                            appState.openInExplorer(path: folder.path, forceRescan: false)
                        } label: {
                            Label(folder.name, systemImage: "folder")
                        }
                    }
                }
                Divider()
                Button("Full Rescan from Root") {
                    hoveredNode = nil
                    appState.openInExplorer(path: appState.selectedScanPath, forceRescan: true)
                }
                Button("Clear Scan Cache") {
                    appState.clearScanCache()
                }
            } label: {
                Label(shortPathLabel(appState.selectedScanPath), systemImage: "folder.badge.magnifyingglass")
                    .lineLimit(1)
            }
            .frame(maxWidth: 250)

            Button("Choose Folder…") {
                if let picked = appState.chooseFolder(title: "Select Disk or Folder to Analyze", initialPath: appState.selectedScanPath) {
                    hoveredNode = nil
                    appState.openInExplorer(path: picked, forceRescan: false)
                }
            }
            .buttonStyle(.bordered)

            if appState.isScanning {
                Button("Cancel Scan") {
                    appState.cancelScan()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
                let isZoomedIn = appState.breadcrumbNodes.count > 1
                Button {
                    hoveredNode = nil
                    if appState.scanResult == nil {
                        appState.openInExplorer(path: appState.selectedScanPath, forceRescan: false)
                    } else {
                        appState.refreshCurrentFolder()
                    }
                } label: {
                    Label(
                        appState.scanResult == nil ? "Scan" : (isZoomedIn ? "Refresh Folder" : "Refresh"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderedProminent)
                .help(isZoomedIn
                    ? "Rescan only the currently open folder and splice it into the cached tree"
                    : "Incrementally update changed folders (use the folder menu for Full Rescan from Root)")
            }

            // Live FSEvents cache status indicator (DEC-012)
            if appState.scanResult != nil && !appState.isScanning {
                if appState.currentScanHasFSChanges {
                    Button {
                        appState.refreshDirtyFolders()
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(Color.orange).frame(width: 7, height: 7)
                            let label = appState.dirtyFolderCount > 0
                                ? "\(appState.dirtyFolderCount) folder(s) changed • Update"
                                : "Files changed • Update"
                            Text(label)
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.14))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Incrementally rescan ONLY the changed folder(s) and keep untouched folders cached")
                } else {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text(appState.currentScanIsFromCache ? "Cached • Live Watch" : "Up to Date • Live Watch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.10))
                    .clipShape(Capsule())
                    .help("Scan is cached in memory and on disk; FSEvents watches for filesystem changes automatically")
                }
            }

            Spacer()

            if let scope = appState.unfilteredScopeNode {
                Button {
                    appState.openFolderCleanupFromExplorer(folderPath: scope.path)
                } label: {
                    Label("Clean Folder by Rule…", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .help("Open Rule-Based Folder Cleanup pre-filled with this folder and active filters")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Date", selection: $appState.storageFilter.datePreset) {
                    ForEach(DateFilterPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .frame(width: 185)

                if appState.storageFilter.datePreset == .custom {
                    DatePicker(
                        "Not older than",
                        selection: Binding(
                            get: { appState.storageFilter.notOlderThan ?? Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date() },
                            set: { appState.storageFilter.notOlderThan = $0 }
                        ),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .help("Not older than (start date)")

                    Text("to")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    DatePicker(
                        "Not newer than",
                        selection: Binding(
                            get: { appState.storageFilter.notNewerThan ?? Date() },
                            set: { appState.storageFilter.notNewerThan = $0 }
                        ),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .help("Not newer than (end date)")
                }

                Picker("Min Size", selection: $appState.storageFilter.minimumSizeBytes) {
                    ForEach(minSizeOptions, id: \.bytes) { opt in
                        Text(opt.label).tag(opt.bytes)
                    }
                }
                .frame(width: 145)

                TextField("Ext (e.g. zip, mp4)", text: $customExtInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 135)
                    .onChange(of: customExtInput) { _, newValue in
                        let parsed = newValue
                            .split(separator: ",")
                            .map {
                                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                                    .lowercased()
                            }
                            .filter { !$0.isEmpty }
                        appState.storageFilter.customExtensions = parsed
                    }

                TextField("Search filename or path…", text: $appState.storageFilter.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 150, maxWidth: 230)

                Spacer()

                if appState.storageFilter.isActive {
                    Button("Clear Filters") {
                        customExtInput = ""
                        appState.resetFilters()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.blue)
                }
            }

            // Single-click focus category filter chips (Cmd-click to combine multiple categories)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("Filter:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    let allSelected = appState.storageFilter.includedCategories.isEmpty
                    Button {
                        appState.storageFilter.includedCategories = []
                    } label: {
                        Text("All")
                            .font(.caption.weight(allSelected ? .semibold : .regular))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(allSelected ? Color.accentColor.opacity(0.24) : Color.primary.opacity(0.06))
                            .overlay(Capsule().stroke(allSelected ? Color.accentColor : Color.clear, lineWidth: 1))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    ForEach(FileCategory.allCases) { category in
                        let selected = appState.storageFilter.includedCategories.contains(category)
                        Button {
                            let isMultiModifier = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
                            if isMultiModifier {
                                if selected {
                                    appState.storageFilter.includedCategories.remove(category)
                                } else {
                                    appState.storageFilter.includedCategories.insert(category)
                                }
                            } else {
                                if appState.storageFilter.includedCategories == [category] {
                                    appState.storageFilter.includedCategories = []
                                } else {
                                    appState.storageFilter.includedCategories = [category]
                                }
                            }
                        } label: {
                            Text(category.displayName)
                                .font(.caption.weight(selected ? .semibold : .regular))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(selected ? Color.accentColor.opacity(0.24) : Color.primary.opacity(0.06))
                                .overlay(Capsule().stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Click to filter only \(category.displayName); ⌘-click to combine multiple types")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var scanningProgressBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            if let prog = appState.scanProgress {
                Text("Scanning… \(prog.filesScanned.formatted()) files, \(ByteFormatting.string(from: prog.bytesAccumulated)) accounted • \(prog.currentPath)")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Scanning \(appState.selectedScanPath)…")
                    .font(.caption)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.08))
    }

    private func incompleteScanBanner(_ result: ScanResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            if result.wasCancelled {
                Text("Partial scan result (cancelled early). Totals represent only items scanned before cancellation.")
                    .font(.caption)
            } else {
                Text("Incomplete scan: \(result.issues.count) folder(s) or file(s) could not be accessed due to macOS permissions.")
                    .font(.caption)
            }
            Spacer()
            if !result.issues.isEmpty {
                Button("View Inaccessible Paths") {
                    showIssuesPopover.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .popover(isPresented: $showIssuesPopover) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Inaccessible Paths (\(result.issues.count))")
                            .font(.headline)
                        Text("Grant Full Disk Access to Disk Steward in System Settings → Privacy & Security to scan protected folders.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        List(result.issues.prefix(100)) { issue in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.path).font(.caption.monospaced())
                                Text(issue.reason).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 440, height: 240)
                    }
                    .padding(12)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }

    private func breadcrumbBar(snapshot: ExplorerSnapshot) -> some View {
        HStack(spacing: 6) {
            Button {
                hoveredNode = nil
                appState.navigateUp()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(appState.breadcrumbNodes.count <= 1)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(appState.breadcrumbNodes.enumerated()), id: \.element.id) { idx, node in
                        if idx > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button(node.name) {
                            hoveredNode = nil
                            appState.navigateBreadcrumb(to: node)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption.weight(idx == appState.breadcrumbNodes.count - 1 ? .semibold : .regular))
                    }
                }
            }

            Spacer()

            Text("\(ByteFormatting.string(from: snapshot.scopeAllocatedBytes)) • \(snapshot.scopeFileCount.formatted()) file(s)")
                .font(.caption.weight(.semibold).monospacedDigit())
            Text("• Sized by allocated disk space")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func hoverStatusBar(snapshot: ExplorerSnapshot) -> some View {
        HStack(spacing: 8) {
            if let hovered = hoveredNode {
                Image(systemName: hovered.isDirectory ? "folder.fill" : hovered.category.systemImage)
                    .foregroundStyle(.secondary)
                Text(hovered.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                let pct = snapshot.scopeAllocatedBytes > 0
                    ? ByteFormatting.percentString(Double(hovered.allocatedSize) / Double(snapshot.scopeAllocatedBytes))
                    : "0%"
                Text("\(ByteFormatting.string(from: hovered.allocatedSize)) (\(pct))")
                    .font(.caption.weight(.semibold).monospacedDigit())
                Text("• \(hovered.isDirectory ? "\(hovered.fileCount.formatted()) files" : hovered.category.displayName) • \(hovered.modifiedDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Showing direct folders and files sized strictly by disk usage. Click any folder to drill in one level; right-click to clean by rule or reveal in Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let result = appState.scanResult {
                    Text(result.duration > 0 ? String(format: "Scanned in %.2fs", result.duration) : "Loaded from cache")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Right Inspector Views (100% Precomputed Off-Main-Thread!)

    private func largestItemsList(snapshot: ExplorerSnapshot) -> some View {
        let scopeTotal = max(Int64(1), snapshot.scopeAllocatedBytes)

        return List(snapshot.largestItems) { item in
            let frac = Double(item.allocatedSize) / Double(scopeTotal)
            HStack(spacing: 8) {
                Image(systemName: item.category.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(item.category.displayName) • \(item.modifiedDate.formatted(date: .abbreviated, time: .omitted)) • \(item.path)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteFormatting.string(from: item.allocatedSize))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Text(ByteFormatting.percentString(frac))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                appState.selectedNodeID = item.id
            }
            .contextMenu {
                Button("Reveal in Finder") {
                    appState.revealInFinder(path: item.path)
                }
                let parent = URL(fileURLWithPath: item.path).deletingLastPathComponent().path
                Button("Clean Containing Folder by Rule…") {
                    appState.openFolderCleanupFromExplorer(folderPath: parent)
                }
            }
        }
        .listStyle(.inset)
    }

    private func categoryBreakdownView(snapshot: ExplorerSnapshot) -> some View {
        List(snapshot.categoryBreakdown) { row in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: row.category.systemImage)
                        .foregroundStyle(.secondary)
                    Text(row.category.displayName)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(ByteFormatting.string(from: row.totalBytes))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                ProgressView(value: row.fraction)
                    .tint(.accentColor)
                HStack {
                    Text("\(row.fileCount.formatted()) file(s)")
                    Spacer()
                    Text(ByteFormatting.percentString(row.fraction))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture {
                if appState.storageFilter.includedCategories == [row.category] {
                    appState.storageFilter.includedCategories = []
                } else {
                    appState.storageFilter.includedCategories = [row.category]
                }
            }
        }
        .listStyle(.inset)
    }

    private func dateBreakdownView(snapshot: ExplorerSnapshot) -> some View {
        List(snapshot.ageBreakdown) { row in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(row.bucket.colorSpec.swiftUIColor)
                        .frame(width: 12, height: 12)
                    Text(row.bucket.displayName)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(ByteFormatting.string(from: row.totalBytes))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                ProgressView(value: row.fraction)
                    .tint(row.bucket.colorSpec.swiftUIColor)
                HStack {
                    Text(row.bucket.colorSpec.explanation)
                        .lineLimit(1)
                    Spacer()
                    Text("\(row.fileCount.formatted()) file(s) • \(ByteFormatting.percentString(row.fraction))")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
        .listStyle(.inset)
    }

    private var emptyExplorerState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 46))
                .foregroundStyle(Color.accentColor)
            Text("Visual Storage Explorer")
                .font(.title2.weight(.semibold))
            Text("Select a disk or folder to explore storage usage. Completed scans are cached automatically and invalidated by macOS FSEvents when files change.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            HStack(spacing: 10) {
                Button {
                    appState.openInExplorer(path: appState.selectedScanPath, forceRescan: false)
                } label: {
                    Label("Scan \(shortPathLabel(appState.selectedScanPath))", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)

                Button("Choose Another Folder…") {
                    if let picked = appState.chooseFolder(title: "Select Folder to Analyze") {
                        appState.openInExplorer(path: picked, forceRescan: false)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortPathLabel(_ path: String) -> String {
        if path == "/" { return "Macintosh HD (/)" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func commonShortcutFolders() -> [(name: String, path: String)] {
        let home = NSHomeDirectory()
        let names = ["Downloads", "Documents", "Desktop", "Movies", "Pictures", "Projects", "github.com"]
        var items: [(String, String)] = [("Home", home)]
        for name in names {
            let full = (home as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: full) {
                items.append((name, full))
            }
        }
        return items
    }
}
