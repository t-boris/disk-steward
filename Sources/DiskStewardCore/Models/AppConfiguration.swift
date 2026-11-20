import Foundation

/// Persisted application settings and workflow configuration.
public struct AppConfiguration: Codable, Hashable, Sendable {
    public var volumeRefreshIntervalSeconds: TimeInterval
    public var archiveJobs: [ArchiveJob]
    public var cleanupRules: [CleanupRule]
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
        cleanupRules: [CleanupRule] = [],
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
        self.cleanupRules = cleanupRules
        self.cleanupLargeFileThresholdBytes = max(1_000_000, cleanupLargeFileThresholdBytes)
        self.cleanupOldInstallerAgeDays = max(0, cleanupOldInstallerAgeDays)
        self.cleanupUserFileRoots = cleanupUserFileRoots ?? Self.defaultUserFileRoots()
        self.nodeModulesSearchRoots = nodeModulesSearchRoots ?? Self.defaultNodeModulesRoots()
        self.includeCacheCleanup = includeCacheCleanup
        self.includeDockerCleanup = includeDockerCleanup
        self.trackedVolumePaths = trackedVolumePaths
    }

    enum CodingKeys: String, CodingKey {
        case volumeRefreshIntervalSeconds
        case archiveJobs
        case cleanupRules
        case cleanupLargeFileThresholdBytes
        case cleanupOldInstallerAgeDays
        case cleanupUserFileRoots
        case nodeModulesSearchRoots
        case includeCacheCleanup
        case includeDockerCleanup
        case trackedVolumePaths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumeRefreshIntervalSeconds = max(5, try c.decodeIfPresent(TimeInterval.self, forKey: .volumeRefreshIntervalSeconds) ?? 30)
        archiveJobs = try c.decodeIfPresent([ArchiveJob].self, forKey: .archiveJobs) ?? []
        cleanupRules = try c.decodeIfPresent([CleanupRule].self, forKey: .cleanupRules) ?? []
        cleanupLargeFileThresholdBytes = max(1_000_000, try c.decodeIfPresent(Int64.self, forKey: .cleanupLargeFileThresholdBytes) ?? 100 * 1_000_000)
        cleanupOldInstallerAgeDays = max(0, try c.decodeIfPresent(Int.self, forKey: .cleanupOldInstallerAgeDays) ?? 14)
        cleanupUserFileRoots = try c.decodeIfPresent([String].self, forKey: .cleanupUserFileRoots) ?? Self.defaultUserFileRoots()
        nodeModulesSearchRoots = try c.decodeIfPresent([String].self, forKey: .nodeModulesSearchRoots) ?? Self.defaultNodeModulesRoots()
        includeCacheCleanup = try c.decodeIfPresent(Bool.self, forKey: .includeCacheCleanup) ?? true
        includeDockerCleanup = try c.decodeIfPresent(Bool.self, forKey: .includeDockerCleanup) ?? true
        trackedVolumePaths = try c.decodeIfPresent([String].self, forKey: .trackedVolumePaths) ?? []
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
