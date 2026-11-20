import AppKit
import DiskStewardCore
import SwiftUI

private enum InspectorTab: String, CaseIterable, Identifiable {
    case largest = "Largest Items"
    case byType = "By File Type"
    case byDate = "By Date"

    var id: String { rawValue }
}

/// Visual storage explorer with a multi-level structural treemap sized purely by allocated bytes,
/// folder drill-down, single-focus or combined filters inside any folder, and direct link to rule-based cleanup (REQ-003, REQ-004, DEC-010, DEC-011).
struct StorageExplorerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var inspectorTab: InspectorTab = .largest
    @State private var showIssuesPopover: Bool = false
    @State private var customExtInput: String = ""

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
            } else if let result = appState.scanResult, !result.isComplete {
                incompleteScanBanner(result)
                Divider()
            }

            if let scope = appState.activeScopeNode {
                breadcrumbBar(scope: scope)
                Divider()

                HSplitView {
                    // Left: Deep Nested Structural Treemap + Hover Status Strip
                    VStack(spacing: 10) {
                        TreemapView(
                            scopeNode: scope,
                            selectedNodeID: appState.selectedNodeID,
                            onHover: { appState.hoveredNode = $0 },
                            onSelect: { appState.selectedNodeID = $0.id },
                            onDrillDown: { appState.drillDown(to: $0) },
                            onRevealInFinder: { appState.revealInFinder(path: $0) },
                            onCleanFolderByRule: { appState.openFolderCleanupFromExplorer(folderPath: $0) }
                        )
                        .frame(minHeight: 340)

                        hoverStatusBar(scope: scope)
                    }
                    .padding(14)
                    .frame(minWidth: 440)

                    // Right: Largest Items / By File Type / By Date Breakdowns
                    VStack(spacing: 10) {
                        Picker("Inspector", selection: $inspectorTab) {
                            ForEach(InspectorTab.allCases) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)

                        switch inspectorTab {
                        case .largest:
                            largestItemsList(scope: scope)
                        case .byType:
                            categoryBreakdownView(scope: scope)
                        case .byDate:
                            dateBreakdownView(scope: scope)
                        }
                    }
                    .padding(14)
                    .frame(minWidth: 320, idealWidth: 380)
                }
            } else if appState.scanResult != nil && appState.storageFilter.isActive {
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
    }

    // MARK: - Controls

    private var topControlBar: some View {
        HStack(spacing: 10) {
            Menu {
                Section("Connected Disks") {
                    ForEach(appState.connectedVolumes) { volume in
                        Button {
                            appState.startScan(path: volume.mountPath)
                        } label: {
                            Label("\(volume.name) (\(volume.mountPath))", systemImage: volume.isMainDisk ? "internaldrive" : "externaldrive")
                        }
                    }
                }
                Section("Common Folders") {
                    ForEach(commonShortcutFolders(), id: \.path) { folder in
                        Button {
                            appState.startScan(path: folder.path)
                        } label: {
                            Label(folder.name, systemImage: "folder")
                        }
                    }
                }
            } label: {
                Label(shortPathLabel(appState.selectedScanPath), systemImage: "folder.badge.magnifyingglass")
                    .lineLimit(1)
            }
            .frame(maxWidth: 260)

            Button("Choose Folder…") {
                if let picked = appState.chooseFolder(title: "Select Disk or Folder to Analyze", initialPath: appState.selectedScanPath) {
                    appState.startScan(path: picked)
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
                Button {
                    appState.startScan()
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
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
                                // Single-click selects only this category (clicking it again returns to All).
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

    private func breadcrumbBar(scope: StorageNode) -> some View {
        HStack(spacing: 6) {
            Button {
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
                            appState.navigateBreadcrumb(to: node)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption.weight(idx == appState.breadcrumbNodes.count - 1 ? .semibold : .regular))
                    }
                }
            }

            Spacer()

            Text("\(ByteFormatting.string(from: scope.allocatedSize)) • \(scope.fileCount.formatted()) file(s)")
                .font(.caption.weight(.semibold).monospacedDigit())
            Text("• Sized by allocated disk space")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func hoverStatusBar(scope: StorageNode) -> some View {
        HStack(spacing: 8) {
            if let hovered = appState.hoveredNode {
                Image(systemName: hovered.isDirectory ? "folder.fill" : hovered.category.systemImage)
                    .foregroundStyle(.secondary)
                Text(hovered.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                let pct = scope.allocatedSize > 0
                    ? ByteFormatting.percentString(Double(hovered.allocatedSize) / Double(scope.allocatedSize))
                    : "0%"
                Text("\(ByteFormatting.string(from: hovered.allocatedSize)) (\(pct))")
                    .font(.caption.weight(.semibold).monospacedDigit())
                Text("• \(hovered.isDirectory ? "\(hovered.fileCount.formatted()) files" : hovered.category.displayName) • \(hovered.modifiedDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Nested rectangles are sized strictly by allocated disk space. Click any folder to zoom in; right-click to clean by rule or reveal in Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let result = appState.scanResult {
                    Text(String(format: "Scanned in %.2fs", result.duration))
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

    // MARK: - Right Inspector Views

    private func largestItemsList(scope: StorageNode) -> some View {
        let items = StorageAnalyzer.largestItems(in: scope, includeDirectories: false, limit: 150)
        let scopeTotal = max(Int64(1), scope.allocatedSize)

        return List(items) { item in
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

    private func categoryBreakdownView(scope: StorageNode) -> some View {
        let rows = StorageAnalyzer.categoryBreakdown(in: scope)
        return List(rows) { row in
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

    private func dateBreakdownView(scope: StorageNode) -> some View {
        let rows = StorageAnalyzer.ageBreakdown(in: scope)
        return VStack(spacing: 0) {
            List(rows) { row in
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
    }

    private var emptyExplorerState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 46))
                .foregroundStyle(Color.accentColor)
            Text("Visual Storage Explorer")
                .font(.title2.weight(.semibold))
            Text("Select a disk or folder and click Scan to explore nested storage hierarchy sized proportionally by allocated space.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            HStack(spacing: 10) {
                Button {
                    appState.startScan()
                } label: {
                    Label("Scan \(shortPathLabel(appState.selectedScanPath))", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)

                Button("Choose Another Folder…") {
                    if let picked = appState.chooseFolder(title: "Select Folder to Analyze") {
                        appState.startScan(path: picked)
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
