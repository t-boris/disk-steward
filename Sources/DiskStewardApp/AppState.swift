import AppKit
import Combine
import DiskStewardCore
import Foundation
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case explorer
    case archiving
    case cleanup
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .explorer: return "Storage Explorer"
        case .archiving: return "Archiving"
        case .cleanup: return "Cleanup"
        case .activity: return "Activity & History"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .explorer: return "square.grid.2x2"
        case .archiving: return "archivebox"
        case .cleanup: return "sparkles"
        case .activity: return "clock.arrow.circlepath"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    // MARK: - Navigation
    @Published var selectedSection: AppSection = .overview

    // MARK: - Persisted Configuration & Operational State
    @Published var configuration: AppConfiguration
    @Published var pendingArchiveRuns: [PendingArchiveRun]
    @Published var verifiedArchives: [VerifiedArchiveRecord]
    @Published var archiveRunHistory: [ArchiveRunReport]
    @Published var cleanupHistory: [CleanupExecutionResult]

    // MARK: - Disk Monitoring (REQ-002)
    @Published var volumes: [DiskVolume] = []
    @Published var lastVolumeRefresh: Date?

    // MARK: - Storage Explorer (REQ-003, REQ-004, DEC-010, DEC-012)
    @Published var selectedScanPath: String
    @Published var isScanning: Bool = false
    @Published var isRefreshingBackgroundCache: Bool = false
    @Published var scanProgress: ScanProgress?
    @Published var scanResult: ScanResult?
    @Published var currentZoomPath: String?
    @Published var storageFilter: StorageFilter = StorageFilter()
    @Published var selectedNodeID: String?
    @Published var explorerSnapshot: ExplorerSnapshot?
    @Published var isComputingSnapshot: Bool = false
    @Published var currentScanIsFromCache: Bool = false
    @Published var currentScanHasFSChanges: Bool = false
    @Published var dirtyFolderCount: Int = 0

    // MARK: - Archiving (REQ-005)
    @Published var selectedArchiveJobID: UUID?
    @Published var isArchiving: Bool = false
    @Published var activeArchiveProgress: ArchiveProgress?
    @Published var previewPlan: ArchivePlan?
    @Published var isBuildingPlan: Bool = false

    // MARK: - Cleanup (REQ-006, DEC-011)
    @Published var isScanningCleanup: Bool = false
    @Published var cleanupProposal: CleanupProposal?
    @Published var selectedCleanupIDs: Set<String> = []
    @Published var showingCleanupConfirmation: Bool = false
    @Published var isExecutingCleanup: Bool = false
    @Published var lastCleanupResult: CleanupExecutionResult?
    @Published var activeCleanupRule: CleanupRule
    @Published var isEvaluatingCleanupRule: Bool = false
    @Published var cleanupActiveCategoryFilter: CleanupCategory? = nil

    // MARK: - Status Feedback
    @Published var statusBanner: String?

    // MARK: - Services
    private let configStore: ConfigurationStore
    private let volumeMonitor: VolumeMonitor
    private let storageScanner: StorageScanner
    private let scanCacheManager: ScanCacheManager
    private var fsWatcher: FileSystemWatcher?
    private let archiveRuleEngine: ArchiveRuleEngine
    private let archiveExecutor: ArchiveExecutor
    private let archiveScheduler: ArchiveScheduler
    private let cleanupScanner: CleanupScanner
    private let cleanupExecutor: CleanupExecutor

    private struct SnapshotCacheKey: Hashable {
        let scanTimestamp: TimeInterval
        let zoomPath: String
        let filter: StorageFilter
    }
    private var explorerSnapshotCache: [SnapshotCacheKey: ExplorerSnapshot] = [:]
    private var snapshotGeneration: UInt64 = 0

    private var scanTask: Task<Void, Never>?
    private var autoRefreshDebounceTask: Task<Void, Never>?
    private var archiveTask: Task<ArchiveExecutionOutput, Never>?
    private nonisolated(unsafe) var volumeTimer: Timer?
    private nonisolated(unsafe) var scheduleTimer: Timer?
    private nonisolated(unsafe) var workspaceObservers: [NSObjectProtocol] = []

    init(configStore: ConfigurationStore = ConfigurationStore()) {
        self.configStore = configStore
        let loaded = configStore.load()

        self.configuration = loaded.configuration
        self.pendingArchiveRuns = loaded.pendingArchiveRuns
        self.verifiedArchives = loaded.verifiedArchives
        self.archiveRunHistory = loaded.archiveRunHistory
        self.cleanupHistory = loaded.cleanupHistory
        self.selectedArchiveJobID = loaded.configuration.archiveJobs.first?.id

        let homeDownloads = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
        let defaultFolder = FileManager.default.fileExists(atPath: homeDownloads) ? homeDownloads : NSHomeDirectory()
        self.selectedScanPath = defaultFolder
        self.activeCleanupRule = CleanupRule(
            name: "Folder Cleanup Rule",
            folderPath: defaultFolder,
            includeSubdirectories: true,
            skipHiddenFiles: true,
            fileCategories: [.archives],
            customExtensions: ["zip"]
        )

        let tracked = loaded.configuration.trackedVolumePaths
            + loaded.configuration.archiveJobs.flatMap(\.configuredDestinations)
        self.volumeMonitor = VolumeMonitor(trackedPaths: tracked)
        self.storageScanner = StorageScanner()
        self.scanCacheManager = ScanCacheManager()
        self.archiveRuleEngine = ArchiveRuleEngine()
        self.archiveExecutor = ArchiveExecutor(ruleEngine: ArchiveRuleEngine())
        self.archiveScheduler = ArchiveScheduler()
        self.cleanupScanner = CleanupScanner()
        self.cleanupExecutor = CleanupExecutor()

        self.fsWatcher = FileSystemWatcher { [weak self] changedPaths in
            Task { @MainActor [weak self] in
                self?.handleFileSystemChanges(changedPaths)
            }
        }

        refreshVolumes()
        startMonitoringTimers()
        registerWorkspaceVolumeObservers()

        // Automatically run read-only cleanup discovery in the background (DEC-001, DEC-003).
        Task { [weak self] in
            await self?.refreshCleanupProposals()
        }
    }

    deinit {
        volumeTimer?.invalidate()
        scheduleTimer?.invalidate()
        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    // MARK: - Derived Indicators

    var menuBarSymbolName: String {
        if isArchiving { return "arrow.triangle.2.circlepath.circle.fill" }
        if !pendingArchiveRuns.isEmpty { return "exclamationmark.triangle.fill" }
        return "internaldrive.fill"
    }

    var connectedVolumes: [DiskVolume] {
        volumes.filter(\.isConnected)
    }

    var disconnectedVolumes: [DiskVolume] {
        volumes.filter { !$0.isConnected }
    }

    var mountedVolumePathSet: Set<String> {
        Set(connectedVolumes.map(\.mountPath))
    }

    var totalProposedReclaimableBytes: Int64 {
        cleanupProposal?.totalEstimatedReclaimableBytes ?? 0
    }

    var cleanupCandidateCount: Int {
        cleanupProposal?.candidates.count ?? 0
    }

    var unfilteredScopeNode: StorageNode? {
        guard let root = scanResult?.root else { return nil }
        if let zoom = currentZoomPath, let zoomed = root.findNode(at: zoom) {
            return zoomed
        }
        return root
    }

    var breadcrumbNodes: [StorageNode] {
        guard let root = scanResult?.root else { return [] }
        guard let zoom = currentZoomPath, zoom != root.path else { return [root] }

        var trail: [StorageNode] = [root]
        var cursor = root
        while cursor.path != zoom {
            if let next = cursor.children.first(where: { zoom == $0.path || zoom.hasPrefix($0.path + "/") }) {
                trail.append(next)
                cursor = next
            } else {
                break
            }
        }
        return trail
    }

    // MARK: - Persistence

    func persistState() {
        let state = PersistedAppState(
            configuration: configuration,
            pendingArchiveRuns: pendingArchiveRuns,
            verifiedArchives: verifiedArchives,
            archiveRunHistory: Array(archiveRunHistory.prefix(100)),
            cleanupHistory: Array(cleanupHistory.prefix(100))
        )
        do {
            try configStore.save(state)
        } catch {
            statusBanner = "Failed to save configuration: \(error.localizedDescription)"
        }
    }

    // MARK: - Volume Monitoring (REQ-002)

    func refreshVolumes() {
        let destinations = configuration.archiveJobs.flatMap(\.configuredDestinations) + configuration.trackedVolumePaths
        volumeMonitor.registerTrackedDestinationPaths(destinations)
        let now = Date()
        volumes = volumeMonitor.refresh(at: now)
        lastVolumeRefresh = now
    }

    func updateVolumeRefreshInterval(_ seconds: TimeInterval) {
        configuration.volumeRefreshIntervalSeconds = max(5, seconds)
        persistState()
        restartVolumeTimer()
    }

    private func startMonitoringTimers() {
        restartVolumeTimer()
        scheduleTimer?.invalidate()
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.evaluateArchiveSchedules()
            }
        }
    }

    private func restartVolumeTimer() {
        volumeTimer?.invalidate()
        let interval = max(5, configuration.volumeRefreshIntervalSeconds)
        volumeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshVolumes()
            }
        }
    }

    private func registerWorkspaceVolumeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let mountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let mountedURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshVolumes()
                if let mountPath = mountedURL?.standardizedFileURL.path {
                    await self.handleVolumeMounted(mountPath)
                }
            }
        }

        let unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshVolumes()
            }
        }

        workspaceObservers = [mountObserver, unmountObserver]
    }

    // MARK: - Storage Scanning, Caching & FSEvents Exploration (REQ-003, REQ-004, DEC-012)

    /// Opens `path` in Storage Explorer using the cache whenever available and clean:
    /// - Clean cache hit (memory, ancestor subtree, or LZFSE disk snapshot): displays instantaneously without rescanning.
    /// - Dirty cache hit (FSEvents detected filesystem changes): displays cached data immediately and refreshes in background.
    /// - Cache miss or `forceRescan == true`: runs fast parallel POSIX scan and caches result + starts FSEvents watcher.
    func openInExplorer(path: String? = nil, forceRescan: Bool = false) {
        let rawTarget = path ?? selectedScanPath
        let target = URL(fileURLWithPath: rawTarget).standardizedFileURL.path
        selectedScanPath = target
        statusBanner = nil

        if !forceRescan {
            // Fast synchronous in-memory & ancestor-subtree check first
            if let memHit = scanCacheManager.lookup(path: target, loadFromDiskIfNeeded: false) {
                applyScanResult(memHit.result, fromCache: true, isDirty: memHit.isDirty, dirtyCount: memHit.minimalDirtyDirectories.count)
                if memHit.isDirty {
                    refreshDirtyFolders(forRoot: target)
                }
                return
            }

            // Check LZFSE compressed disk snapshot off-main-thread before launching a full scan
            let cacheManager = scanCacheManager
            isScanning = true
            scanProgress = nil
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let diskHit = cacheManager.lookup(path: target, loadFromDiskIfNeeded: true)
                DispatchQueue.main.async {
                    guard let self, self.selectedScanPath == target else { return }
                    if let diskHit {
                        self.isScanning = false
                        self.applyScanResult(diskHit.result, fromCache: true, isDirty: diskHit.isDirty, dirtyCount: diskHit.minimalDirtyDirectories.count)
                        self.updateFileSystemWatchers()
                        if diskHit.isDirty {
                            self.refreshDirtyFolders(forRoot: target)
                        }
                    } else {
                        self.startScan(path: target, backgroundRefresh: false)
                    }
                }
            }
            return
        }

        startScan(path: target, backgroundRefresh: false)
    }

    /// Incrementally rescans ONLY the changed directories detected by FSEvents and splices them
    /// back into the cached root tree (never rescanning untouched folders from root, DEC-012).
    /// When `scopedToDirectory` is given, rescans only dirty directories inside that folder.
    func refreshDirtyFolders(forRoot overrideRoot: String? = nil, scopedToDirectory: String? = nil) {
        let rootPath = URL(fileURLWithPath: overrideRoot ?? scanResult?.root.path ?? selectedScanPath).standardizedFileURL.path
        guard let cached = scanCacheManager.lookup(path: rootPath, loadFromDiskIfNeeded: false) else {
            startScan(path: rootPath, backgroundRefresh: false)
            return
        }

        var dirtyDirs = cached.minimalDirtyDirectories
        if let scopeDir = scopedToDirectory {
            let stdScope = URL(fileURLWithPath: scopeDir).standardizedFileURL.path
            dirtyDirs = dirtyDirs.filter { dir in
                dir == stdScope || dir.hasPrefix(stdScope + "/") || stdScope.hasPrefix(dir + "/")
            }
        }

        guard !dirtyDirs.isEmpty else {
            if scopedToDirectory == nil {
                currentScanHasFSChanges = false
                dirtyFolderCount = 0
            }
            return
        }

        // Never escalate an incremental click to a full root scan if only subdirectories changed.
        if dirtyDirs.count == 1 && dirtyDirs[0] == rootPath {
            startScan(path: rootPath, backgroundRefresh: true)
            return
        }

        // Rescan at most 20 dirty directories per pass; any remaining stay cleanly queued.
        let batchToScan = Array(dirtyDirs.prefix(20))

        scanTask?.cancel()
        isRefreshingBackgroundCache = true
        let scanner = storageScanner
        let cacheManager = scanCacheManager

        scanTask = Task { [weak self] in
            let start = CFAbsoluteTimeGetCurrent()
            var updates: [(path: String, node: StorageNode?, addedIssues: [ScanIssue])] = []
            let fm = FileManager.default

            for dirPath in batchToScan {
                if Task.isCancelled { break }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue {
                    let subRes = await scanner.scan(rootURL: URL(fileURLWithPath: dirPath), stayOnSameVolume: true)
                    if !subRes.wasCancelled {
                        updates.append((path: dirPath, node: subRes.root, addedIssues: subRes.issues))
                    }
                } else {
                    updates.append((path: dirPath, node: nil, addedIssues: []))
                }
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            guard !Task.isCancelled, !updates.isEmpty else {
                await MainActor.run { [weak self] in
                    self?.isRefreshingBackgroundCache = false
                }
                return
            }

            let patched = cacheManager.applyIncrementalUpdate(
                rootPath: rootPath,
                updatedSubtrees: updates,
                duration: elapsed,
                persistToDisk: true
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRefreshingBackgroundCache = false
                if let patched {
                    let remaining = cacheManager.lookup(path: rootPath, loadFromDiskIfNeeded: false)?.minimalDirtyDirectories.count ?? 0
                    self.applyScanResult(
                        patched,
                        fromCache: true,
                        isDirty: remaining > 0,
                        dirtyCount: remaining,
                        preserveZoomIfValid: true
                    )
                    self.statusBanner = String(
                        format: "Updated %d changed folder(s) in %.2fs (untouched folders kept from cache).",
                        updates.count,
                        elapsed
                    )
                }
            }
        }
    }

    /// Incrementally rescans ONLY the currently opened subfolder (currentZoomPath) and splices it back
    /// into the cached root tree without rescanning any sibling folders (DEC-012).
    func refreshCurrentFolder() {
        guard let rootPath = scanResult?.root.path else {
            openInExplorer(path: selectedScanPath, forceRescan: true)
            return
        }
        let stdRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let targetFolder = URL(fileURLWithPath: currentZoomPath ?? stdRoot).standardizedFileURL.path

        // If user is at root and there are specific dirty folders, only rescan those dirty folders!
        if targetFolder == stdRoot {
            if let cached = scanCacheManager.lookup(path: stdRoot, loadFromDiskIfNeeded: false),
               cached.isDirty,
               cached.canIncrementalRefresh {
                refreshDirtyFolders(forRoot: stdRoot)
                return
            }
            startScan(path: stdRoot, backgroundRefresh: false)
            return
        }

        // Zoomed inside a subfolder: rescan ONLY that subfolder and splice into the cached root tree!
        scanTask?.cancel()
        isRefreshingBackgroundCache = true
        let scanner = storageScanner
        let cacheManager = scanCacheManager

        scanTask = Task { [weak self] in
            let start = CFAbsoluteTimeGetCurrent()
            let fm = FileManager.default
            var isDir: ObjCBool = false
            let update: (path: String, node: StorageNode?, addedIssues: [ScanIssue])

            if fm.fileExists(atPath: targetFolder, isDirectory: &isDir), isDir.boolValue {
                let subRes = await scanner.scan(rootURL: URL(fileURLWithPath: targetFolder), stayOnSameVolume: true)
                if subRes.wasCancelled {
                    await MainActor.run { [weak self] in self?.isRefreshingBackgroundCache = false }
                    return
                }
                update = (path: targetFolder, node: subRes.root, addedIssues: subRes.issues)
            } else {
                update = (path: targetFolder, node: nil, addedIssues: [])
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let patched = cacheManager.applyIncrementalUpdate(
                rootPath: stdRoot,
                updatedSubtrees: [update],
                duration: elapsed,
                persistToDisk: true
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRefreshingBackgroundCache = false
                if let patched {
                    let remainingDirty = cacheManager.lookup(path: stdRoot, loadFromDiskIfNeeded: false)?.minimalDirtyDirectories.count ?? 0
                    self.applyScanResult(
                        patched,
                        fromCache: true,
                        isDirty: remainingDirty > 0,
                        dirtyCount: remainingDirty,
                        preserveZoomIfValid: true
                    )
                    let folderName = URL(fileURLWithPath: targetFolder).lastPathComponent
                    self.statusBanner = String(format: "Updated folder '%@' in %.2fs.", folderName, elapsed)
                }
            }
        }
    }

    func startScan(path: String? = nil, backgroundRefresh: Bool = false) {
        let rawTarget = path ?? selectedScanPath
        let target = URL(fileURLWithPath: rawTarget).standardizedFileURL.path
        selectedScanPath = target
        scanTask?.cancel()

        if backgroundRefresh {
            isRefreshingBackgroundCache = true
        } else {
            isScanning = true
            scanProgress = nil
            selectedNodeID = nil
        }
        statusBanner = nil

        let scanner = storageScanner
        let cacheManager = scanCacheManager
        let url = URL(fileURLWithPath: target)
        let onProgress: @Sendable (ScanProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                self?.scanProgress = progress
            }
        }

        scanTask = Task { [weak self] in
            let result = await scanner.scan(rootURL: url, stayOnSameVolume: true, progressHandler: onProgress)
            if !result.wasCancelled {
                cacheManager.store(result, persistToDisk: true)
            }
            await MainActor.run { [weak self] in
                guard let self, self.selectedScanPath == target else { return }
                self.isScanning = false
                self.isRefreshingBackgroundCache = false
                self.scanProgress = nil
                self.applyScanResult(result, fromCache: false, isDirty: false, preserveZoomIfValid: backgroundRefresh)
                self.updateFileSystemWatchers()
            }
        }
    }

    private func applyScanResult(
        _ result: ScanResult,
        fromCache: Bool,
        isDirty: Bool,
        dirtyCount: Int = 0,
        preserveZoomIfValid: Bool = false
    ) {
        scanResult = result
        currentScanIsFromCache = fromCache
        currentScanHasFSChanges = isDirty
        dirtyFolderCount = dirtyCount

        if preserveZoomIfValid,
           let existingZoom = currentZoomPath {
            if result.root.findNode(at: existingZoom) != nil {
                // Keep user right inside the folder they were viewing
            } else {
                // If the zoomed folder itself was deleted, step cleanly to its nearest surviving ancestor
                var fallback = URL(fileURLWithPath: existingZoom).deletingLastPathComponent().standardizedFileURL.path
                while fallback.count >= result.root.path.count {
                    if result.root.findNode(at: fallback) != nil {
                        currentZoomPath = fallback
                        break
                    }
                    let parent = URL(fileURLWithPath: fallback).deletingLastPathComponent().standardizedFileURL.path
                    if parent == fallback {
                        currentZoomPath = result.root.path
                        break
                    }
                    fallback = parent
                }
                if currentZoomPath == existingZoom {
                    currentZoomPath = result.root.path
                }
            }
        } else {
            currentZoomPath = result.root.path
        }
        selectedNodeID = nil
        explorerSnapshotCache.removeAll()
        refreshExplorerSnapshot()
    }

    /// Recomputes ExplorerSnapshot off the Main Thread with instant cache hit when revisiting folders or filters (DEC-012).
    func refreshExplorerSnapshot() {
        guard let result = scanResult, let scope = unfilteredScopeNode else {
            explorerSnapshot = nil
            isComputingSnapshot = false
            return
        }

        let key = SnapshotCacheKey(
            scanTimestamp: result.scannedAt.timeIntervalSinceReferenceDate,
            zoomPath: scope.path,
            filter: storageFilter
        )
        if let cached = explorerSnapshotCache[key] {
            explorerSnapshot = cached
            isComputingSnapshot = false
            return
        }

        // Fast optimistic update for unfiltered drill-down so Treemap updates on the EXACT click frame (0ms)!
        if !storageFilter.isActive {
            explorerSnapshot = ExplorerSnapshot(
                scopePath: scope.path,
                scopeName: scope.name,
                scopeAllocatedBytes: scope.allocatedSize,
                scopeFileCount: scope.fileCount,
                directChildren: scope.children,
                largestItems: explorerSnapshot?.largestItems ?? [],
                categoryBreakdown: explorerSnapshot?.categoryBreakdown ?? [],
                ageBreakdown: explorerSnapshot?.ageBreakdown ?? [],
                isEmptyDueToFilter: false
            )
        }

        snapshotGeneration &+= 1
        let expectedGen = snapshotGeneration
        let activeFilter = storageFilter
        isComputingSnapshot = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = StorageAnalyzer.buildSnapshot(for: scope, filter: activeFilter, largestLimit: 150)
            DispatchQueue.main.async {
                guard let self, self.snapshotGeneration == expectedGen else { return }
                if self.explorerSnapshotCache.count > 64 {
                    self.explorerSnapshotCache.removeAll()
                }
                self.explorerSnapshotCache[key] = snapshot
                self.explorerSnapshot = snapshot
                self.isComputingSnapshot = false
            }
        }
    }

    /// Loads an existing LZFSE disk cache snapshot for `selectedScanPath` on first view appear without launching a scan.
    func loadCachedExplorerIfAvailable() {
        guard scanResult == nil, !isScanning else { return }
        let target = URL(fileURLWithPath: selectedScanPath).standardizedFileURL.path
        let cacheManager = scanCacheManager
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hit = cacheManager.lookup(path: target, loadFromDiskIfNeeded: true)
            DispatchQueue.main.async {
                guard let self, self.scanResult == nil, !self.isScanning, self.selectedScanPath == target else { return }
                if let hit {
                    self.applyScanResult(hit.result, fromCache: true, isDirty: hit.isDirty)
                    self.updateFileSystemWatchers()
                }
            }
        }
    }

    func clearScanCache() {
        scanCacheManager.clearAll()
        explorerSnapshotCache.removeAll()
        fsWatcher?.stop()
        currentScanIsFromCache = false
        currentScanHasFSChanges = false
        statusBanner = "Cleared storage scan cache."
    }

    private func updateFileSystemWatchers() {
        let roots = scanCacheManager.cachedRootPaths
        fsWatcher?.watch(paths: roots)
    }

    private func handleFileSystemChanges(_ changedPaths: [String]) {
        let dirtyRoots = scanCacheManager.invalidate(changedPaths: changedPaths)
        guard !dirtyRoots.isEmpty else { return }
        if let currentRoot = scanResult?.root.path {
            let stdCurrent = URL(fileURLWithPath: currentRoot).standardizedFileURL.path
            if dirtyRoots.contains(stdCurrent) {
                let dirtyDirs = scanCacheManager.lookup(path: stdCurrent, loadFromDiskIfNeeded: false)?.minimalDirtyDirectories ?? []
                currentScanHasFSChanges = !dirtyDirs.isEmpty
                dirtyFolderCount = dirtyDirs.count

                // If changes occurred inside the folder the user is currently viewing (when zoomed in,
                // or a small localized change), auto-splice those changed folders smoothly after a short 1.5s debounce!
                if selectedSection == .explorer, !isScanning, !isRefreshingBackgroundCache {
                    let activeZoom = URL(fileURLWithPath: currentZoomPath ?? stdCurrent).standardizedFileURL.path
                    let affectsActiveFolder = dirtyDirs.contains { dir in
                        dir == activeZoom || dir.hasPrefix(activeZoom + "/")
                    }
                    if affectsActiveFolder && dirtyDirs.count <= 6 {
                        autoRefreshDebounceTask?.cancel()
                        autoRefreshDebounceTask = Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            guard !Task.isCancelled, let self else { return }
                            guard !self.isScanning, !self.isRefreshingBackgroundCache else { return }
                            self.refreshDirtyFolders(forRoot: stdCurrent, scopedToDirectory: activeZoom)
                        }
                    }
                }
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
        isRefreshingBackgroundCache = false
    }

    func exploreVolume(_ volume: DiskVolume) {
        guard volume.isConnected else { return }
        selectedSection = .explorer
        openInExplorer(path: volume.mountPath, forceRescan: false)
    }

    func drillDown(to node: StorageNode) {
        guard node.isDirectory else {
            selectedNodeID = node.id
            return
        }
        currentZoomPath = node.path
        selectedNodeID = nil
        refreshExplorerSnapshot()

        // If this newly entered folder has queued dirty subfolders, splice them silently right away!
        if let rootPath = scanResult?.root.path, currentScanHasFSChanges, !isScanning, !isRefreshingBackgroundCache {
            let stdRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
            if let cached = scanCacheManager.lookup(path: stdRoot, loadFromDiskIfNeeded: false) {
                let targetPath = URL(fileURLWithPath: node.path).standardizedFileURL.path
                let hasDirtyInside = cached.minimalDirtyDirectories.contains { dir in
                    dir == targetPath || dir.hasPrefix(targetPath + "/")
                }
                if hasDirtyInside {
                    refreshDirtyFolders(forRoot: stdRoot, scopedToDirectory: targetPath)
                }
            }
        }
    }

    func navigateBreadcrumb(to node: StorageNode) {
        currentZoomPath = node.path
        selectedNodeID = nil
        refreshExplorerSnapshot()
    }

    func navigateUp() {
        let trail = breadcrumbNodes
        guard trail.count > 1 else { return }
        currentZoomPath = trail[trail.count - 2].path
        selectedNodeID = nil
        refreshExplorerSnapshot()
    }

    func resetFilters() {
        storageFilter = StorageFilter()
        refreshExplorerSnapshot()
    }

    // MARK: - Rule-Based Folder Cleanup (DEC-011)

    func openFolderCleanupFromExplorer(folderPath: String) {
        let folderName = URL(fileURLWithPath: folderPath).lastPathComponent
        var categories = Array(storageFilter.includedCategories)
        let extensions = storageFilter.customExtensions
        if categories.isEmpty && extensions.isEmpty {
            categories = [.archives]
        }

        let olderDays: Int?
        switch storageFilter.datePreset {
        case .olderThan30Days: olderDays = 30
        case .olderThan6Months: olderDays = 180
        case .olderThan1Year: olderDays = 365
        default: olderDays = nil
        }

        activeCleanupRule = CleanupRule(
            name: "Clean \(folderName)",
            folderPath: folderPath,
            includeSubdirectories: true,
            skipHiddenFiles: true,
            fileCategories: categories,
            customExtensions: extensions,
            fileNameMatchMode: storageFilter.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .any : .contains,
            fileNamePattern: storageFilter.searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            olderThanDays: olderDays,
            minimumSizeBytes: storageFilter.minimumSizeBytes
        )
        cleanupActiveCategoryFilter = .ruleMatches
        selectedSection = .cleanup

        Task { [weak self] in
            guard let self else { return }
            await self.runCleanupRule(self.activeCleanupRule)
        }
    }

    func runCleanupRule(_ rule: CleanupRule) async {
        isEvaluatingCleanupRule = true
        let engine = CleanupRuleEngine()
        let (matched, ruleNotes): ([CleanupCandidate], [String]) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let res = autoreleasepool { engine.evaluate(rule: rule) }
                continuation.resume(returning: res)
            }
        }

        isEvaluatingCleanupRule = false

        let existingNonRule = (cleanupProposal?.candidates ?? []).filter { $0.category != .ruleMatches }
        let existingNotes = cleanupProposal?.notes ?? []
        let mergedProposal = CleanupProposal(
            createdAt: Date(),
            candidates: matched + existingNonRule,
            notes: ruleNotes + existingNotes,
            dockerStatusMessage: cleanupProposal?.dockerStatusMessage
        )
        cleanupProposal = mergedProposal
        cleanupActiveCategoryFilter = .ruleMatches

        // Pre-select all newly matched files so the user can review and confirm deletion immediately (DEC-003).
        selectedCleanupIDs = Set(matched.map(\.id))

        if matched.isEmpty {
            statusBanner = ruleNotes.first ?? "No files matched rule '\(rule.name)' in \(rule.folderPath)."
        } else {
            let totalBytes = matched.reduce(Int64(0)) { $0 + $1.estimatedReclaimableBytes }
            statusBanner = "Rule '\(rule.name)' matched \(matched.count) file(s) (\(ByteFormatting.string(from: totalBytes))). Review and confirm deletion when ready."
        }
    }

    func saveCleanupRule(_ rule: CleanupRule) {
        if let idx = configuration.cleanupRules.firstIndex(where: { $0.id == rule.id }) {
            configuration.cleanupRules[idx] = rule
        } else {
            configuration.cleanupRules.append(rule)
        }
        persistState()
        statusBanner = "Saved cleanup rule '\(rule.name)'."
    }

    func deleteCleanupRule(id: UUID) {
        configuration.cleanupRules.removeAll { $0.id == id }
        persistState()
    }

    // MARK: - Classified Archiving & Scheduling (REQ-005)

    func addArchiveJob(_ job: ArchiveJob) {
        configuration.archiveJobs.append(job)
        selectedArchiveJobID = job.id
        persistState()
        refreshVolumes()
    }

    func updateArchiveJob(_ job: ArchiveJob) {
        if let idx = configuration.archiveJobs.firstIndex(where: { $0.id == job.id }) {
            configuration.archiveJobs[idx] = job
            persistState()
            refreshVolumes()
        }
    }

    func deleteArchiveJob(id: UUID) {
        configuration.archiveJobs.removeAll { $0.id == id }
        pendingArchiveRuns.removeAll { $0.jobID == id }
        if selectedArchiveJobID == id {
            selectedArchiveJobID = configuration.archiveJobs.first?.id
        }
        if previewPlan?.jobID == id {
            previewPlan = nil
        }
        persistState()
    }

    func previewArchiveJob(_ job: ArchiveJob) {
        isBuildingPlan = true
        let engine = archiveRuleEngine
        let mounted = mountedVolumePathSet
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let plan = autoreleasepool { engine.buildPlan(for: job, mountedVolumePaths: mounted) }
            DispatchQueue.main.async {
                self?.previewPlan = plan
                self?.isBuildingPlan = false
            }
        }
    }

    func runArchiveJob(_ job: ArchiveJob, trigger: ArchiveTrigger = .onDemand) async {
        guard archiveScheduler.beginRun(for: job.id) else {
            statusBanner = "Archive job '\(job.name)' is already running."
            return
        }
        defer { archiveScheduler.endRun(for: job.id) }

        isArchiving = true
        activeArchiveProgress = nil
        refreshVolumes()
        let mounted = mountedVolumePathSet
        let executor = archiveExecutor

        let onArchiveProgress: @Sendable (ArchiveProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                self?.activeArchiveProgress = progress
            }
        }

        let task = Task.detached(priority: .userInitiated) {
            await executor.execute(job: job, trigger: trigger, mountedVolumePaths: mounted, progressHandler: onArchiveProgress)
        }
        archiveTask = task
        let output = await task.value
        archiveTask = nil

        isArchiving = false
        activeArchiveProgress = nil

        // Keep persisted history compact while preserving all failure/warning/renamed outcomes.
        let importantOutcomes = output.report.outcomes.filter {
            $0.kind == .failed || $0.kind == .skippedSourceChanged || $0.kind == .copiedRenamed || $0.kind == .interrupted
        }
        let regularOutcomes = output.report.outcomes.filter {
            $0.kind == .copied || $0.kind == .skippedDuplicate || $0.kind == .skippedUnmatched || $0.kind == .destinationUnavailable
        }
        let cappedOutcomes = Array((importantOutcomes + regularOutcomes).prefix(500))
        let compactReport = ArchiveRunReport(
            id: output.report.id,
            jobID: output.report.jobID,
            jobName: output.report.jobName,
            trigger: output.report.trigger,
            startedAt: output.report.startedAt,
            finishedAt: output.report.finishedAt,
            status: output.report.status,
            copiedCount: output.report.copiedCount,
            renamedCount: output.report.renamedCount,
            duplicateCount: output.report.duplicateCount,
            unmatchedCount: output.report.unmatchedCount,
            sourceChangedCount: output.report.sourceChangedCount,
            failedCount: output.report.failedCount,
            interruptedCount: output.report.interruptedCount,
            bytesCopied: output.report.bytesCopied,
            unavailableDestinations: output.report.unavailableDestinations,
            outcomes: cappedOutcomes
        )
        archiveRunHistory.insert(compactReport, at: 0)

        if output.report.status == .deferredDestinationUnavailable {
            // Keep pending until destination volume reconnects (DEC-004).
            let roots = Array(Set(output.report.unavailableDestinations.map { VolumeMonitor.volumeRootPath(forDestination: $0) })).sorted()
            if let idx = pendingArchiveRuns.firstIndex(where: { $0.jobID == job.id }) {
                pendingArchiveRuns[idx].missedRunCount += 1
                pendingArchiveRuns[idx].latestMissedAt = Date()
                pendingArchiveRuns[idx].missingDestinationPaths = output.report.unavailableDestinations
                pendingArchiveRuns[idx].requiredVolumeRoots = roots
            } else {
                pendingArchiveRuns.append(
                    PendingArchiveRun(
                        jobID: job.id,
                        jobName: job.name,
                        firstScheduledAt: Date(),
                        missingDestinationPaths: output.report.unavailableDestinations,
                        requiredVolumeRoots: roots
                    )
                )
            }
            statusBanner = "Archive job '\(job.name)' is pending until destination disk \(roots.joined(separator: ", ")) is connected."
        } else {
            // Clear pending run if it succeeded or completed.
            pendingArchiveRuns.removeAll { $0.jobID == job.id }
            if let idx = configuration.archiveJobs.firstIndex(where: { $0.id == job.id }) {
                configuration.archiveJobs[idx].lastRunAt = output.report.finishedAt
            }

            // Merge newly verified SHA-256 archive records (originals are NEVER auto-deleted, DEC-003).
            for record in output.verifiedRecords {
                verifiedArchives.removeAll { $0.sourcePath == record.sourcePath }
                verifiedArchives.append(record)
            }

            // Invalidate cached scans of destination folders written during archiving (DEC-012).
            let writtenDests = output.verifiedRecords.map(\.destinationPath)
            if !writtenDests.isEmpty {
                handleFileSystemChanges(writtenDests)
            }

            let copiedTotal = output.report.copiedCount + output.report.renamedCount
            statusBanner = "Archive '\(job.name)': \(copiedTotal) copied, \(output.report.duplicateCount) duplicates skipped, \(output.report.unmatchedCount) unmatched. Originals retained until confirmed in Cleanup."

            // Refresh read-only cleanup proposals so newly verified archived originals appear for user review.
            await refreshCleanupProposals()
        }

        persistState()
    }

    func cancelActiveArchive() {
        archiveTask?.cancel()
        statusBanner = "Cancelling active archive run…"
    }

    func evaluateArchiveSchedules() async {
        refreshVolumes()
        let eval = archiveScheduler.evaluate(
            jobs: configuration.archiveJobs,
            pendingRuns: pendingArchiveRuns,
            now: Date(),
            mountedVolumePaths: mountedVolumePathSet
        )
        pendingArchiveRuns = eval.updatedPendingRuns
        persistState()

        for request in eval.readyRuns {
            if let job = configuration.archiveJobs.first(where: { $0.id == request.jobID }) {
                await runArchiveJob(job, trigger: request.trigger)
            }
        }
    }

    private func handleVolumeMounted(_ volumePath: String) async {
        let eval = archiveScheduler.handleVolumeMounted(
            volumePath: volumePath,
            jobs: configuration.archiveJobs,
            pendingRuns: pendingArchiveRuns,
            mountedVolumePaths: mountedVolumePathSet
        )
        pendingArchiveRuns = eval.updatedPendingRuns
        persistState()

        for request in eval.readyRuns {
            if let job = configuration.archiveJobs.first(where: { $0.id == request.jobID }) {
                statusBanner = "Destination disk connected. Resuming deferred archive job '\(job.name)'..."
                await runArchiveJob(job, trigger: request.trigger)
            }
        }
    }

    // MARK: - Cleanup Discovery & Confirmed Deletion (REQ-006, DEC-003, DEC-006)

    func refreshCleanupProposals() async {
        isScanningCleanup = true
        let config = configuration
        let records = verifiedArchives
        let scanner = cleanupScanner

        let proposal = await Task.detached(priority: .utility) {
            await scanner.discoverProposals(configuration: config, verifiedArchives: records)
        }.value

        cleanupProposal = proposal
        // Keep only still-valid selections.
        let validIDs = Set(proposal.candidates.map(\.id))
        selectedCleanupIDs = selectedCleanupIDs.intersection(validIDs)
        isScanningCleanup = false
    }

    func toggleCleanupCandidate(_ id: String) {
        if selectedCleanupIDs.contains(id) {
            selectedCleanupIDs.remove(id)
        } else {
            selectedCleanupIDs.insert(id)
        }
    }

    func selectAllCleanup(in category: CleanupCategory) {
        guard let proposal = cleanupProposal else { return }
        for item in proposal.candidates(in: category) {
            selectedCleanupIDs.insert(item.id)
        }
    }

    func deselectAllCleanup(in category: CleanupCategory) {
        guard let proposal = cleanupProposal else { return }
        for item in proposal.candidates(in: category) {
            selectedCleanupIDs.remove(item.id)
        }
    }

    // MARK: - Persistent Cleanup Exclusions / Dismiss (DEC-013)

    /// Persistently dismisses a single cleanup proposal so it will not reappear until restored.
    func ignoreCleanupCandidate(_ candidate: CleanupCandidate) {
        let exclusion = CleanupExclusion(
            candidateID: candidate.id,
            pathPrefix: candidate.isDockerArtifact ? nil : candidate.location,
            label: candidate.title
        )
        addCleanupExclusions([exclusion])
        statusBanner = "Ignored '\(candidate.title)'. It will not appear in future cleanup proposals."
    }

    /// Persistently dismisses all currently selected cleanup proposals.
    func ignoreSelectedCleanupCandidates() {
        let selected = selectedCleanupCandidates
        guard !selected.isEmpty else { return }
        let exclusions = selected.map { candidate in
            CleanupExclusion(
                candidateID: candidate.id,
                pathPrefix: candidate.isDockerArtifact ? nil : candidate.location,
                label: candidate.title
            )
        }
        addCleanupExclusions(exclusions)
        statusBanner = "Ignored \(selected.count) cleanup proposal(s). You can restore them anytime from Ignored Items."
    }

    /// Persistently ignores an entire folder (and everything inside it) from future cleanup proposals.
    func ignoreCleanupFolder(path: String, label: String? = nil) {
        let stdPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let folderName = label ?? URL(fileURLWithPath: stdPath).lastPathComponent
        let exclusion = CleanupExclusion(
            candidateID: nil,
            pathPrefix: stdPath,
            label: "Folder: \(folderName)"
        )
        addCleanupExclusions([exclusion])
        statusBanner = "Ignored folder '\(stdPath)'. Items inside will no longer appear in cleanup proposals."
    }

    /// Restores a previously ignored item or folder and refreshes cleanup proposals.
    func restoreCleanupExclusion(id: UUID) {
        configuration.cleanupExclusions.removeAll { $0.id == id }
        persistState()
        Task { [weak self] in
            await self?.refreshCleanupProposals()
        }
    }

    /// Restores all ignored items and folders and refreshes cleanup proposals.
    func restoreAllCleanupExclusions() {
        configuration.cleanupExclusions.removeAll()
        persistState()
        statusBanner = "Restored all ignored cleanup items."
        Task { [weak self] in
            await self?.refreshCleanupProposals()
        }
    }

    private func addCleanupExclusions(_ newExclusions: [CleanupExclusion]) {
        for exclusion in newExclusions {
            let alreadyExists = configuration.cleanupExclusions.contains { existing in
                (exclusion.candidateID != nil && existing.candidateID == exclusion.candidateID)
                    || (exclusion.pathPrefix != nil && existing.pathPrefix == exclusion.pathPrefix)
            }
            if !alreadyExists {
                configuration.cleanupExclusions.append(exclusion)
            }
        }
        persistState()

        // Immediately filter out newly excluded candidates from the current visible proposal without waiting for a rescan.
        if let proposal = cleanupProposal {
            let exclusions = configuration.cleanupExclusions
            let remaining = proposal.candidates.filter { candidate in
                !exclusions.contains(where: { $0.matches(candidate) })
            }
            cleanupProposal = CleanupProposal(
                id: proposal.id,
                createdAt: proposal.createdAt,
                candidates: remaining,
                notes: proposal.notes,
                dockerStatusMessage: proposal.dockerStatusMessage
            )
            let remainingIDs = Set(remaining.map(\.id))
            selectedCleanupIDs = selectedCleanupIDs.intersection(remainingIDs)
        }
    }

    var selectedCleanupCandidates: [CleanupCandidate] {
        guard let proposal = cleanupProposal else { return [] }
        return proposal.candidates.filter { selectedCleanupIDs.contains($0.id) }
    }

    var selectedCleanupReclaimableBytes: Int64 {
        selectedCleanupCandidates.reduce(0) { $0 + $1.estimatedReclaimableBytes }
    }

    /// Declines the cleanup confirmation dialog and leaves all data intact (REQ-006 AC 4).
    func declineCleanupConfirmation() {
        showingCleanupConfirmation = false
        statusBanner = "Cleanup cancelled. All proposed files and artifacts were left intact."
    }

    /// Executes deletion ONLY after explicit confirmation in CleanupConfirmationSheet (DEC-003, DEC-006).
    func confirmAndExecuteCleanup(mode: DeletionMode) async {
        guard let proposal = cleanupProposal, !selectedCleanupIDs.isEmpty else {
            showingCleanupConfirmation = false
            return
        }

        showingCleanupConfirmation = false
        isExecutingCleanup = true

        let confirmation = CleanupConfirmation(
            proposalID: proposal.id,
            confirmedCandidateIDs: selectedCleanupIDs,
            deletionMode: mode
        )
        let executor = cleanupExecutor

        let result = await Task.detached(priority: .userInitiated) {
            await executor.execute(proposal: proposal, confirmation: confirmation)
        }.value

        isExecutingCleanup = false
        lastCleanupResult = result
        cleanupHistory.insert(result, at: 0)

        // Remove verified archive records for originals that were actually deleted.
        let deletedLocations = Set(result.itemResults.filter(\.didDelete).map(\.location))
        verifiedArchives.removeAll { deletedLocations.contains($0.sourcePath) }

        // Invalidate affected Storage Explorer caches immediately after deletion (DEC-012).
        if !deletedLocations.isEmpty {
            handleFileSystemChanges(Array(deletedLocations))
        }

        selectedCleanupIDs.removeAll()
        persistState()
        refreshVolumes()

        statusBanner = "Cleanup completed: \(result.succeededCount) removed (\(ByteFormatting.string(from: result.totalReclaimedBytes))), \(result.skippedCount) skipped, \(result.failedCount) failed."
        await refreshCleanupProposals()
    }

    // MARK: - macOS Helpers

    func chooseFolder(title: String = "Select Folder", initialPath: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let initialPath, FileManager.default.fileExists(atPath: initialPath) {
            panel.directoryURL = URL(fileURLWithPath: initialPath)
        }
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL.path : nil
    }

    func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
