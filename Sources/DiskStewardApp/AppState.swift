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
                applyScanResult(memHit.result, fromCache: true, isDirty: memHit.isDirty)
                if memHit.isDirty {
                    startScan(path: target, backgroundRefresh: true)
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
                        self.applyScanResult(diskHit.result, fromCache: true, isDirty: diskHit.isDirty)
                        self.updateFileSystemWatchers()
                        if diskHit.isDirty {
                            self.startScan(path: target, backgroundRefresh: true)
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
        preserveZoomIfValid: Bool = false
    ) {
        scanResult = result
        currentScanIsFromCache = fromCache
        currentScanHasFSChanges = isDirty

        if preserveZoomIfValid,
           let existingZoom = currentZoomPath,
           result.root.findNode(at: existingZoom) != nil {
            // Keep user in the subfolder they were already viewing
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
                currentScanHasFSChanges = true
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
