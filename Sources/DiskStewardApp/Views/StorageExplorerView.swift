import DiskStewardCore
import SwiftUI

private enum InspectorTab: String, CaseIterable, Identifiable {
    case largest = "Largest Items"
    case byType = "By File Type"
    case byDate = "By Date"

    var id: String { rawValue }
}

/// Visual storage explorer combining a proportional squarified treemap, size/type/date breakdowns,
/// filters, and explained date-age colors (REQ-003, REQ-004, plan I-3, I-4).
struct StorageExplorerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var inspectorTab: InspectorTab = .largest
    @State private var showIssuesPopover: Bool = false

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
                    // Left: Treemap + Hover Details + Explained Color Legend
                    VStack(spacing: 10) {
                        TreemapView(
                            scopeNode: scope,
                            colorMode: appState.treemapColorMode,
                            selectedNodeID: appState.selectedNodeID,
                            onHover: { appState.hoveredNode = $0 },
                            onSelect: { appState.selectedNodeID = $0.id },
                            onDrillDown: { appState.drillDown(to: $0) },
                            onRevealInFinder: { appState.revealInFinder(path: $0) }
                        )
                        .frame(minHeight: 300)

                        hoverStatusBar(scope: scope)
                        colorLegendBar
                    }
                    .padding(14)
                    .frame(minWidth: 420)

                    // Right: Largest Items / By File Type / By Date Breakdowns
                    VStack(spacing: 10) {
                        Picker("Inspector", selection: $inspectorTab) {
                            ForEach(InspectorTab.allCases) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
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
                    Text("No files match the active filters.")
                        .font(.headline)
                    Button("Reset Filters") {
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

            Picker("Colors", selection: $appState.treemapColorMode) {
                ForEach(TreemapColorMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 310)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // Date filter preset
                Picker("Date", selection: $appState.storageFilter.datePreset) {
                    ForEach(DateFilterPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .frame(width: 190)

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

                TextField("Search filename or path…", text: $appState.storageFilter.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160, maxWidth: 240)

                Spacer()

                if appState.storageFilter.isActive {
                    Button("Clear Filters") {
                        appState.resetFilters()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.blue)
                }
            }

            // File type multi-select filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("File Types:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    ForEach(FileCategory.allCases) { category in
                        let selected = appState.storageFilter.includedCategories.contains(category)
                        Button {
                            if selected {
                                appState.storageFilter.includedCategories.remove(category)
                            } else {
                                appState.storageFilter.includedCategories.insert(category)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(category.colorSpec.swiftUIColor)
                                    .frame(width: 7, height: 7)
                                Text(category.displayName)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
                            .overlay(
                                Capsule().stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1)
                            )
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
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
            Text("• Size: Allocated on-disk • Date: Last modified")
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
                Text("Allocated: \(ByteFormatting.string(from: hovered.allocatedSize))")
                    .font(.caption.weight(.semibold).monospacedDigit())
                Text("• Modified: \(hovered.modifiedDate.formatted(date: .abbreviated, time: .omitted)) (\(hovered.ageBucket().displayName))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Hover a rectangle to inspect details. Click a folder to drill down; right-click to reveal in Finder.")
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

    /// Always-visible color explanation legend (REQ-004 AC 3).
    private var colorLegendBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(appState.treemapColorMode == .byDateAge ? "Date Age Color Legend (Last Modified Date):" : "File Type Color Legend:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            let specs = appState.treemapColorMode == .byDateAge
                ? StorageAnalyzer.dateColorLegend
                : StorageAnalyzer.categoryColorLegend

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(specs, id: \.label) { spec in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(spec.swiftUIColor)
                                .frame(width: 12, height: 12)
                            Text(spec.label)
                                .font(.caption.weight(.medium))
                        }
                        .help(spec.explanation)
                    }
                }
            }
            if appState.treemapColorMode == .byDateAge {
                Text("Cool blue indicates recently modified files (< 7 days); amber and coral highlight older files (> 6 months / > 1 year) that are strong candidates for archiving or cleanup.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Right Inspector Views

    private func largestItemsList(scope: StorageNode) -> some View {
        let items = StorageAnalyzer.largestItems(in: scope, includeDirectories: false, limit: 150)
        let scopeTotal = max(Int64(1), scope.allocatedSize)

        return List(items) { item in
            let frac = Double(item.allocatedSize) / Double(scopeTotal)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(item.ageBucket().colorSpec.swiftUIColor)
                    .frame(width: 5, height: 28)
                    .help(item.ageBucket().colorSpec.explanation)

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
            }
        }
        .listStyle(.inset)
    }

    private func categoryBreakdownView(scope: StorageNode) -> some View {
        let rows = StorageAnalyzer.categoryBreakdown(in: scope)
        return List(rows) { row in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Circle()
                        .fill(row.category.colorSpec.swiftUIColor)
                        .frame(width: 9, height: 9)
                    Text(row.category.displayName)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(ByteFormatting.string(from: row.totalBytes))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                ProgressView(value: row.fraction)
                    .tint(row.category.colorSpec.swiftUIColor)
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
        return List(rows) { row in
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
            Text("Select a disk or folder and click Scan to visualize space usage as a proportional treemap with size, file-type, and date breakdowns.")
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
