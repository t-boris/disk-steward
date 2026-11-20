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

    // MARK: - Storage Explorer (REQ-003, REQ-004)
    @Published var selectedScanPath: String
    @Published var isScanning: Bool = false
    @Published var scanProgress: ScanProgress?
    @Published var scanResult: ScanResult?
    @Published var currentZoomPath: String?
    @Published var storageFilter: StorageFilter = StorageFilter()
    @Published var treemapColorMode: TreemapColorMode = .byDateAge
    @Published var selectedNodeID: String?
    @Published var hoveredNode: StorageNode?

    // MARK: - Archiving (REQ-005)
    @Published var selectedArchiveJobID: UUID?
    @Published var isArchiving: Bool = false
    @Published var activeArchiveProgress: ArchiveProgress?
    @Published var previewPlan: ArchivePlan?
    @Published var isBuildingPlan: Bool = false

    // MARK: - Cleanup (REQ-006)
    @Published var isScanningCleanup: Bool = false
    @Published var cleanupProposal: CleanupProposal?
    @Published var selectedCleanupIDs: Set<String> = []
    @Published var showingCleanupConfirmation: Bool = false
    @Published var isExecutingCleanup: Bool = false
    @Published var lastCleanupResult: CleanupExecutionResult?

    // MARK: - Status Feedback
    @Published var statusBanner: String?

    // MARK: - Services
    private let configStore: ConfigurationStore
    private let volumeMonitor: VolumeMonitor
    private let storageScanner: StorageScanner
    private let archiveRuleEngine: ArchiveRuleEngine
    private let archiveExecutor: ArchiveExecutor
    private let archiveScheduler: ArchiveScheduler
    private let cleanupScanner: CleanupScanner
    private let cleanupExecutor: CleanupExecutor

    private var scanTask: Task<Void, Never>?
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
        self.selectedScanPath = FileManager.default.fileExists(atPath: homeDownloads) ? homeDownloads : NSHomeDirectory()

        let tracked = loaded.configuration.trackedVolumePaths
            + loaded.configuration.archiveJobs.flatMap(\.configuredDestinations)
        self.volumeMonitor = VolumeMonitor(trackedPaths: tracked)
        self.storageScanner = StorageScanner()
        self.archiveRuleEngine = ArchiveRuleEngine()
        self.archiveExecutor = ArchiveExecutor(ruleEngine: ArchiveRuleEngine())
        self.archiveScheduler = ArchiveScheduler()
        self.cleanupScanner = CleanupScanner()
        self.cleanupExecutor = CleanupExecutor()

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

    var activeScopeNode: StorageNode? {
        guard let root = scanResult?.root else { return nil }
        let baseNode: StorageNode
        if let zoom = currentZoomPath, let zoomed = root.findNode(at: zoom) {
            baseNode = zoomed
        } else {
            baseNode = root
        }
        return StorageAnalyzer.filteredTree(baseNode, filter: storageFilter)
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

    // MARK: - Storage Scanning & Exploration (REQ-003, REQ-004)

    func startScan(path: String? = nil) {
        let target = path ?? selectedScanPath
        selectedScanPath = target
        scanTask?.cancel()
        isScanning = true
        scanProgress = nil
        currentZoomPath = nil
        selectedNodeID = nil
        hoveredNode = nil
        statusBanner = nil

        let scanner = storageScanner
        let url = URL(fileURLWithPath: target)
        let onProgress: @Sendable (ScanProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                self?.scanProgress = progress
            }
        }
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = await scanner.scan(rootURL: url, stayOnSameVolume: true, progressHandler: onProgress)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.scanResult = result
                self.currentZoomPath = result.root.path
                self.isScanning = false
                self.scanProgress = nil
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
    }

    func exploreVolume(_ volume: DiskVolume) {
        guard volume.isConnected else { return }
        selectedSection = .explorer
        startScan(path: volume.mountPath)
    }

    func drillDown(to node: StorageNode) {
        guard node.isDirectory else {
            selectedNodeID = node.id
            return
        }
        currentZoomPath = node.path
        selectedNodeID = nil
    }

    func navigateBreadcrumb(to node: StorageNode) {
        currentZoomPath = node.path
        selectedNodeID = nil
    }

    func navigateUp() {
        let trail = breadcrumbNodes
        guard trail.count > 1 else { return }
        currentZoomPath = trail[trail.count - 2].path
        selectedNodeID = nil
    }

    func resetFilters() {
        storageFilter = StorageFilter()
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
        Task.detached(priority: .userInitiated) { [weak self] in
            let plan = engine.buildPlan(for: job, mountedVolumePaths: mounted)
            await MainActor.run { [weak self] in
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

        let output = await Task.detached(priority: .userInitiated) {
            await executor.execute(job: job, trigger: trigger, mountedVolumePaths: mounted, progressHandler: onArchiveProgress)
        }.value

        isArchiving = false
        activeArchiveProgress = nil

        archiveRunHistory.insert(output.report, at: 0)

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

            let copiedTotal = output.report.copiedCount + output.report.renamedCount
            statusBanner = "Archive '\(job.name)': \(copiedTotal) copied, \(output.report.duplicateCount) duplicates skipped, \(output.report.unmatchedCount) unmatched. Originals retained until confirmed in Cleanup."

            // Refresh read-only cleanup proposals so newly verified archived originals appear for user review.
            await refreshCleanupProposals()
        }

        persistState()
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
