import Foundation

/// Persisted application settings and workflow configuration.
public struct AppConfiguration: Codable, Hashable, Sendable {
    public var volumeRefreshIntervalSeconds: TimeInterval
    public var archiveJobs: [ArchiveJob]
    public var cleanupLargeFileThresholdBytes: Int64
    public var cleanupOldInstallerAgeDays: Int
    public var cleanupUserFileRoots: [String]
    public var nodeModulesSearchRoots: [String]
    public var includeCacheCleanup: Bool
    public var includeDockerCleanup: Bool
    public var trackedVolumePaths: [String]

    public init(
        volumeRefreshIntervalSeconds: TimeInterval = 30,
        archiveJobs: [ArchiveJob] = [],
        cleanupLargeFileThresholdBytes: Int64 = 100 * 1_000_000, // 100 MB
        cleanupOldInstallerAgeDays: Int = 14,
        cleanupUserFileRoots: [String]? = nil,
        nodeModulesSearchRoots: [String]? = nil,
        includeCacheCleanup: Bool = true,
        includeDockerCleanup: Bool = true,
        trackedVolumePaths: [String] = []
    ) {
        self.volumeRefreshIntervalSeconds = max(5, volumeRefreshIntervalSeconds)
        self.archiveJobs = archiveJobs
        self.cleanupLargeFileThresholdBytes = max(1_000_000, cleanupLargeFileThresholdBytes)
        self.cleanupOldInstallerAgeDays = max(0, cleanupOldInstallerAgeDays)
        self.cleanupUserFileRoots = cleanupUserFileRoots ?? Self.defaultUserFileRoots()
        self.nodeModulesSearchRoots = nodeModulesSearchRoots ?? Self.defaultNodeModulesRoots()
        self.includeCacheCleanup = includeCacheCleanup
        self.includeDockerCleanup = includeDockerCleanup
        self.trackedVolumePaths = trackedVolumePaths
    }

    public static func defaultUserFileRoots(homeDirectory: String = NSHomeDirectory()) -> [String] {
        let candidates = ["Downloads", "Desktop"].map { (homeDirectory as NSString).appendingPathComponent($0) }
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }

    public static func defaultNodeModulesRoots(homeDirectory: String = NSHomeDirectory()) -> [String] {
        let candidates = ["Projects", "github.com", "Developer", "Code", "workspace", "src"].map {
            (homeDirectory as NSString).appendingPathComponent($0)
        }
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }
}

/// Persisted operational state across launches (deferred archive runs, verified archive index, and run history).
public struct PersistedAppState: Codable, Sendable {
    public var configuration: AppConfiguration
    public var pendingArchiveRuns: [PendingArchiveRun]
    public var verifiedArchives: [VerifiedArchiveRecord]
    public var archiveRunHistory: [ArchiveRunReport]
    public var cleanupHistory: [CleanupExecutionResult]

    public init(
        configuration: AppConfiguration = AppConfiguration(),
        pendingArchiveRuns: [PendingArchiveRun] = [],
        verifiedArchives: [VerifiedArchiveRecord] = [],
        archiveRunHistory: [ArchiveRunReport] = [],
        cleanupHistory: [CleanupExecutionResult] = []
    ) {
        self.configuration = configuration
        self.pendingArchiveRuns = pendingArchiveRuns
        self.verifiedArchives = verifiedArchives
        self.archiveRunHistory = archiveRunHistory
        self.cleanupHistory = cleanupHistory
    }
}
