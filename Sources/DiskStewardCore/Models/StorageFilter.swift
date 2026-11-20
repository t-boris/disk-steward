import Foundation

/// Presets for narrowing storage analysis by file modification date.
public enum DateFilterPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case anyTime
    case last7Days
    case last30Days
    case olderThan30Days
    case olderThan6Months
    case olderThan1Year
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anyTime: return "Any Date"
        case .last7Days: return "Last 7 Days"
        case .last30Days: return "Last 30 Days"
        case .olderThan30Days: return "Older than 30 Days"
        case .olderThan6Months: return "Older than 6 Months"
        case .olderThan1Year: return "Older than 1 Year"
        case .custom: return "Custom Range"
        }
    }
}

/// Color mode for treemap visualization.
public enum TreemapColorMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case byDateAge
    case byFileType

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .byDateAge: return "Color by Age (Date)"
        case .byFileType: return "Color by File Type"
        }
    }
}

/// Filter criteria for narrowing treemap exploration and storage breakdowns (REQ-004, DEC-010).
public struct StorageFilter: Hashable, Codable, Sendable {
    /// Empty means include all file categories.
    public var includedCategories: Set<FileCategory>
    /// Optional specific extensions (lowercase without leading dot, e.g. ["zip", "mp4"]).
    public var customExtensions: [String]
    public var datePreset: DateFilterPreset
    /// Inclusive lower bound ("not older than") when datePreset == .custom.
    public var notOlderThan: Date?
    /// Inclusive upper bound ("not newer than") when datePreset == .custom.
    public var notNewerThan: Date?
    public var minimumSizeBytes: Int64
    public var searchText: String

    public init(
        includedCategories: Set<FileCategory> = [],
        customExtensions: [String] = [],
        datePreset: DateFilterPreset = .anyTime,
        notOlderThan: Date? = nil,
        notNewerThan: Date? = nil,
        minimumSizeBytes: Int64 = 0,
        searchText: String = ""
    ) {
        self.includedCategories = includedCategories
        self.customExtensions = customExtensions.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
        }.filter { !$0.isEmpty }
        self.datePreset = datePreset
        self.notOlderThan = notOlderThan
        self.notNewerThan = notNewerThan
        self.minimumSizeBytes = max(0, minimumSizeBytes)
        self.searchText = searchText
    }

    public var isActive: Bool {
        !includedCategories.isEmpty
            || !customExtensions.isEmpty
            || datePreset != .anyTime
            || minimumSizeBytes > 0
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func matchesFile(_ node: StorageNode, relativeTo now: Date = Date()) -> Bool {
        guard !node.isDirectory else { return true }

        let hasCategoryFilter = !includedCategories.isEmpty
        let hasExtFilter = !customExtensions.isEmpty
        if hasCategoryFilter || hasExtFilter {
            let ext = URL(fileURLWithPath: node.name).pathExtension.lowercased()
            let catMatches = hasCategoryFilter && includedCategories.contains(node.category)
            let extMatches = hasExtFilter && !ext.isEmpty && customExtensions.contains(ext)
            if hasCategoryFilter && hasExtFilter {
                if !catMatches && !extMatches { return false }
            } else if hasCategoryFilter {
                if !catMatches { return false }
            } else {
                if !extMatches { return false }
            }
        }

        if minimumSizeBytes > 0 && node.allocatedSize < minimumSizeBytes {
            return false
        }

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            let haystack = "\(node.name) \(node.path)".lowercased()
            if !haystack.contains(trimmedSearch.lowercased()) {
                return false
            }
        }

        let ageDays = now.timeIntervalSince(node.modifiedDate) / 86_400.0
        switch datePreset {
        case .anyTime:
            break
        case .last7Days:
            if ageDays > 7 { return false }
        case .last30Days:
            if ageDays > 30 { return false }
        case .olderThan30Days:
            if ageDays < 30 { return false }
        case .olderThan6Months:
            if ageDays < 180 { return false }
        case .olderThan1Year:
            if ageDays < 365 { return false }
        case .custom:
            if let lower = notOlderThan, node.modifiedDate < lower {
                return false
            }
            if let upper = notNewerThan, node.modifiedDate > upper {
                return false
            }
        }

        return true
    }
}

/// Aggregated storage usage for one file category.
public struct CategoryBreakdown: Identifiable, Hashable, Sendable {
    public let category: FileCategory
    public let totalBytes: Int64
    public let fileCount: Int
    public let fraction: Double

    public var id: FileCategory { category }

    public init(category: FileCategory, totalBytes: Int64, fileCount: Int, fraction: Double) {
        self.category = category
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.fraction = fraction
    }
}

/// Aggregated storage usage for one age bucket.
public struct AgeBreakdown: Identifiable, Hashable, Sendable {
    public let bucket: AgeBucket
    public let totalBytes: Int64
    public let fileCount: Int
    public let fraction: Double

    public var id: AgeBucket { bucket }

    public init(bucket: AgeBucket, totalBytes: Int64, fileCount: Int, fraction: Double) {
        self.bucket = bucket
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.fraction = fraction
    }
}
