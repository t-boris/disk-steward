import Foundation

/// Matching mode for optional file-name conditions in an archive classification rule.
public enum FileNameMatchMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case any
    case contains
    case startsWith
    case endsWith
    case glob

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .any: return "Any Name"
        case .contains: return "Name Contains"
        case .startsWith: return "Name Starts With"
        case .endsWith: return "Name Ends With"
        case .glob: return "Wildcard Pattern (*, ?)"
        }
    }
}

/// A classification rule mapping matching source files to a configured destination folder (REQ-005, DEC-002).
/// Rules within a job are evaluated in top-to-bottom priority order; the first matching rule wins.
public struct ArchiveRule: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    /// File categories that satisfy the file-type condition (OR'd with customExtensions when non-empty).
    public var fileCategories: [FileCategory]
    /// Custom file extensions (lowercase without leading dot, e.g. "dmg", "raw").
    public var customExtensions: [String]
    public var fileNameMatchMode: FileNameMatchMode
    public var fileNamePattern: String
    /// Optional source folder path prefix restriction (nil or empty matches any configured source folder).
    public var sourceFolderPath: String?
    /// Destination directory where matching files are archived.
    public var destinationFolderPath: String
    /// When true, preserves subdirectories relative to the source folder root inside destinationFolderPath.
    public var preserveRelativeSubpath: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        fileCategories: [FileCategory] = [],
        customExtensions: [String] = [],
        fileNameMatchMode: FileNameMatchMode = .any,
        fileNamePattern: String = "",
        sourceFolderPath: String? = nil,
        destinationFolderPath: String,
        preserveRelativeSubpath: Bool = true
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.fileCategories = fileCategories
        self.customExtensions = customExtensions.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
        }.filter { !$0.isEmpty }
        self.fileNameMatchMode = fileNameMatchMode
        self.fileNamePattern = fileNamePattern
        self.sourceFolderPath = sourceFolderPath?.isEmpty == true ? nil : sourceFolderPath
        self.destinationFolderPath = destinationFolderPath
        self.preserveRelativeSubpath = preserveRelativeSubpath
    }
}

/// Schedule cadence for automated classified archiving (DEC-004).
public enum ArchiveScheduleFrequency: String, CaseIterable, Codable, Sendable, Identifiable {
    case manual
    case hourly
    case daily
    case weekly
    case customIntervalMinutes

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .manual: return "Manual Only"
        case .hourly: return "Every Hour"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .customIntervalMinutes: return "Custom Interval"
        }
    }
}

/// User-defined schedule configuration for an archive job (REQ-005, DEC-004).
public struct ArchiveSchedule: Hashable, Codable, Sendable {
    public var isEnabled: Bool
    public var frequency: ArchiveScheduleFrequency
    /// 0...23 for daily and weekly schedules.
    public var hour: Int
    /// 0...59 for daily and weekly schedules.
    public var minute: Int
    /// 1 (Sunday) ... 7 (Saturday) for weekly schedules.
    public var weekday: Int
    /// Interval in minutes when frequency == .customIntervalMinutes (minimum 5).
    public var intervalMinutes: Int

    public init(
        isEnabled: Bool = false,
        frequency: ArchiveScheduleFrequency = .manual,
        hour: Int = 2,
        minute: Int = 0,
        weekday: Int = 1,
        intervalMinutes: Int = 60
    ) {
        self.isEnabled = isEnabled
        self.frequency = frequency
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.weekday = min(max(weekday, 1), 7)
        self.intervalMinutes = max(5, intervalMinutes)
    }

    public var summaryDescription: String {
        guard isEnabled, frequency != .manual else { return "Manual only" }
        let timeStr = String(format: "%02d:%02d", hour, minute)
        switch frequency {
        case .manual:
            return "Manual only"
        case .hourly:
            return "Every hour"
        case .daily:
            return "Daily at \(timeStr)"
        case .weekly:
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let dayName = names[(weekday - 1) % 7]
            return "Weekly on \(dayName) at \(timeStr)"
        case .customIntervalMinutes:
            return "Every \(intervalMinutes) min"
        }
    }

    /// Computes the next scheduled fire date strictly after `reference`.
    public func nextRunDate(after reference: Date, calendar: Calendar = .current) -> Date? {
        guard isEnabled, frequency != .manual else { return nil }
        switch frequency {
        case .manual:
            return nil
        case .hourly:
            return reference.addingTimeInterval(3600)
        case .customIntervalMinutes:
            return reference.addingTimeInterval(TimeInterval(intervalMinutes * 60))
        case .daily:
            var comps = DateComponents()
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            return calendar.nextDate(after: reference, matching: comps, matchingPolicy: .nextTime)
        case .weekly:
            var comps = DateComponents()
            comps.weekday = weekday
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            return calendar.nextDate(after: reference, matching: comps, matchingPolicy: .nextTime)
        }
    }

    /// Determines whether the schedule is due at `now` given `lastRun` (or `createdAt` if never run).
    public func isDue(lastRun: Date?, createdAt: Date, now: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled, frequency != .manual else { return false }
        let baseline = lastRun ?? createdAt
        guard let next = nextRunDate(after: baseline, calendar: calendar) else { return false }
        return next <= now
    }
}

/// A configured classified archiving job with source folders, ordered routing rules, optional fallback, and schedule.
public struct ArchiveJob: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var sourceFolders: [String]
    public var rules: [ArchiveRule]
    /// Optional fallback folder for files matching no explicit rule (DEC-008). When nil, unmatched files remain untouched.
    public var fallbackDestinationPath: String?
    public var includeSubdirectories: Bool
    /// When true (default), preserves relative subfolder hierarchy inside fallback destination and as the default for new rules (DEC-014).
    public var preserveFolderStructure: Bool
    public var skipHiddenFiles: Bool
    public var schedule: ArchiveSchedule
    public var createdAt: Date
    public var lastRunAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        sourceFolders: [String] = [],
        rules: [ArchiveRule] = [],
        fallbackDestinationPath: String? = nil,
        includeSubdirectories: Bool = true,
        preserveFolderStructure: Bool = true,
        skipHiddenFiles: Bool = true,
        schedule: ArchiveSchedule = ArchiveSchedule(),
        createdAt: Date = Date(),
        lastRunAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceFolders = sourceFolders
        self.rules = rules
        self.fallbackDestinationPath = fallbackDestinationPath?.isEmpty == true ? nil : fallbackDestinationPath
        self.includeSubdirectories = includeSubdirectories
        self.preserveFolderStructure = preserveFolderStructure
        self.skipHiddenFiles = skipHiddenFiles
        self.schedule = schedule
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sourceFolders, rules, fallbackDestinationPath
        case includeSubdirectories, preserveFolderStructure, skipHiddenFiles
        case schedule, createdAt, lastRunAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        sourceFolders = try c.decodeIfPresent([String].self, forKey: .sourceFolders) ?? []
        rules = try c.decodeIfPresent([ArchiveRule].self, forKey: .rules) ?? []
        let rawFallback = try c.decodeIfPresent(String.self, forKey: .fallbackDestinationPath)
        fallbackDestinationPath = rawFallback?.isEmpty == true ? nil : rawFallback
        includeSubdirectories = try c.decodeIfPresent(Bool.self, forKey: .includeSubdirectories) ?? true
        preserveFolderStructure = try c.decodeIfPresent(Bool.self, forKey: .preserveFolderStructure) ?? true
        skipHiddenFiles = try c.decodeIfPresent(Bool.self, forKey: .skipHiddenFiles) ?? true
        schedule = try c.decodeIfPresent(ArchiveSchedule.self, forKey: .schedule) ?? ArchiveSchedule()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
    }

    /// Returns all unique configured destination folders across enabled rules and optional fallback.
    public var configuredDestinations: [String] {
        var paths = rules.filter(\.isEnabled).map(\.destinationFolderPath)
        if let fallback = fallbackDestinationPath, !fallback.isEmpty {
            paths.append(fallback)
        }
        return Array(Set(paths)).sorted()
    }
}

/// Planned action for a single file during classified archiving dry-run preview.
public enum ArchivePlannedAction: String, Codable, Sendable {
    case copy
    case copyWithSuffix
    case skipDuplicate
    case skipUnmatched
    case destinationUnavailable
}

/// One entry in a previewed classified archive plan.
public struct ArchivePlanEntry: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let sourcePath: String
    public let sourceRootPath: String
    public let fileName: String
    public let fileSize: Int64
    public let category: FileCategory
    public let matchedRuleName: String?
    public let destinationPath: String?
    public let action: ArchivePlannedAction
    public let note: String?

    public init(
        id: UUID = UUID(),
        sourcePath: String,
        sourceRootPath: String,
        fileName: String,
        fileSize: Int64,
        category: FileCategory,
        matchedRuleName: String?,
        destinationPath: String?,
        action: ArchivePlannedAction,
        note: String? = nil
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.sourceRootPath = sourceRootPath
        self.fileName = fileName
        self.fileSize = fileSize
        self.category = category
        self.matchedRuleName = matchedRuleName
        self.destinationPath = destinationPath
        self.action = action
        self.note = note
    }
}

/// Dry-run classified archive plan produced before execution (plan I-5).
public struct ArchivePlan: Sendable {
    public let jobID: UUID
    public let jobName: String
    public let createdAt: Date
    public let entries: [ArchivePlanEntry]
    public let unavailableDestinations: [String]
    public let scanErrors: [String]

    public init(
        jobID: UUID,
        jobName: String,
        createdAt: Date = Date(),
        entries: [ArchivePlanEntry],
        unavailableDestinations: [String] = [],
        scanErrors: [String] = []
    ) {
        self.jobID = jobID
        self.jobName = jobName
        self.createdAt = createdAt
        self.entries = entries
        self.unavailableDestinations = unavailableDestinations
        self.scanErrors = scanErrors
    }

    public var copyCount: Int { entries.filter { $0.action == .copy }.count }
    public var copyWithSuffixCount: Int { entries.filter { $0.action == .copyWithSuffix }.count }
    public var duplicateCount: Int { entries.filter { $0.action == .skipDuplicate }.count }
    public var unmatchedCount: Int { entries.filter { $0.action == .skipUnmatched }.count }
    public var unavailableCount: Int { entries.filter { $0.action == .destinationUnavailable }.count }
    public var totalBytesToCopy: Int64 {
        entries
            .filter { $0.action == .copy || $0.action == .copyWithSuffix }
            .reduce(0) { $0 + $1.fileSize }
    }
}

/// Trigger source for an archive run.
public enum ArchiveTrigger: String, Codable, Sendable {
    case onDemand
    case scheduled
    case resumedDeferred

    public var displayName: String {
        switch self {
        case .onDemand: return "On Demand"
        case .scheduled: return "Scheduled"
        case .resumedDeferred: return "Resumed After Reconnect"
        }
    }
}

/// High-level result status of an archive execution.
public enum ArchiveRunStatus: String, Codable, Sendable {
    case completed
    case completedWithErrors
    case deferredDestinationUnavailable
    case cancelled
    case failed

    public var displayName: String {
        switch self {
        case .completed: return "Completed"
        case .completedWithErrors: return "Completed with Errors"
        case .deferredDestinationUnavailable: return "Pending (Destination Unavailable)"
        case .cancelled: return "Interrupted / Cancelled"
        case .failed: return "Failed"
        }
    }
}

/// Per-file outcome of an archive run.
public struct ArchiveItemOutcome: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case copied
        case copiedRenamed
        case skippedDuplicate
        case skippedUnmatched
        case skippedSourceChanged
        case destinationUnavailable
        case failed
        case interrupted
    }

    public let id: UUID
    public let sourcePath: String
    public let destinationPath: String?
    public let kind: Kind
    public let bytesCopied: Int64
    public let sha256: String?
    public let detail: String?

    public init(
        id: UUID = UUID(),
        sourcePath: String,
        destinationPath: String?,
        kind: Kind,
        bytesCopied: Int64 = 0,
        sha256: String? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.kind = kind
        self.bytesCopied = bytesCopied
        self.sha256 = sha256
        self.detail = detail
    }
}

/// Summary report persisted after an archive run completes, fails, or is deferred.
public struct ArchiveRunReport: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let jobID: UUID
    public let jobName: String
    public let trigger: ArchiveTrigger
    public let startedAt: Date
    public let finishedAt: Date
    public let status: ArchiveRunStatus
    public let copiedCount: Int
    public let renamedCount: Int
    public let duplicateCount: Int
    public let unmatchedCount: Int
    public let sourceChangedCount: Int
    public let failedCount: Int
    public let interruptedCount: Int
    public let bytesCopied: Int64
    public let unavailableDestinations: [String]
    public let outcomes: [ArchiveItemOutcome]

    public init(
        id: UUID = UUID(),
        jobID: UUID,
        jobName: String,
        trigger: ArchiveTrigger,
        startedAt: Date,
        finishedAt: Date,
        status: ArchiveRunStatus,
        copiedCount: Int = 0,
        renamedCount: Int = 0,
        duplicateCount: Int = 0,
        unmatchedCount: Int = 0,
        sourceChangedCount: Int = 0,
        failedCount: Int = 0,
        interruptedCount: Int = 0,
        bytesCopied: Int64 = 0,
        unavailableDestinations: [String] = [],
        outcomes: [ArchiveItemOutcome] = []
    ) {
        self.id = id
        self.jobID = jobID
        self.jobName = jobName
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.copiedCount = copiedCount
        self.renamedCount = renamedCount
        self.duplicateCount = duplicateCount
        self.unmatchedCount = unmatchedCount
        self.sourceChangedCount = sourceChangedCount
        self.failedCount = failedCount
        self.interruptedCount = interruptedCount
        self.bytesCopied = bytesCopied
        self.unavailableDestinations = unavailableDestinations
        self.outcomes = outcomes
    }
}

/// A deferred scheduled archive run waiting for one or more destination volumes to reconnect (REQ-005, DEC-004, I-7).
public struct PendingArchiveRun: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var jobID: UUID
    public var jobName: String
    public var firstScheduledAt: Date
    public var latestMissedAt: Date
    public var missedRunCount: Int
    public var missingDestinationPaths: [String]
    public var requiredVolumeRoots: [String]

    public init(
        id: UUID = UUID(),
        jobID: UUID,
        jobName: String,
        firstScheduledAt: Date,
        latestMissedAt: Date? = nil,
        missedRunCount: Int = 1,
        missingDestinationPaths: [String],
        requiredVolumeRoots: [String]
    ) {
        self.id = id
        self.jobID = jobID
        self.jobName = jobName
        self.firstScheduledAt = firstScheduledAt
        self.latestMissedAt = latestMissedAt ?? firstScheduledAt
        self.missedRunCount = max(1, missedRunCount)
        self.missingDestinationPaths = missingDestinationPaths
        self.requiredVolumeRoots = requiredVolumeRoots
    }
}

/// Cryptographically verified record proving an original file has an intact SHA-256 copy in an archive (DEC-007).
public struct VerifiedArchiveRecord: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var jobID: UUID
    public var sourcePath: String
    public var destinationPath: String
    public var sha256: String
    public var fileSize: Int64
    public var sourceModifiedDate: Date
    public var archivedAt: Date

    public init(
        id: UUID = UUID(),
        jobID: UUID,
        sourcePath: String,
        destinationPath: String,
        sha256: String,
        fileSize: Int64,
        sourceModifiedDate: Date,
        archivedAt: Date = Date()
    ) {
        self.id = id
        self.jobID = jobID
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.sha256 = sha256
        self.fileSize = fileSize
        self.sourceModifiedDate = sourceModifiedDate
        self.archivedAt = archivedAt
    }
}
