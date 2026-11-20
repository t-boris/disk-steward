import Foundation

/// Categories of cleanup candidates discovered automatically or via user cleanup rules (REQ-006, DEC-011).
public enum CleanupCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case ruleMatches
    case archivedOriginals
    case userFiles
    case caches
    case dockerArtifacts
    case nodeModules

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ruleMatches: return "Folder Cleanup Rule Matches"
        case .archivedOriginals: return "Archived Originals (Verified)"
        case .userFiles: return "Large & Old User Files"
        case .caches: return "Caches"
        case .dockerArtifacts: return "Docker Artifacts"
        case .nodeModules: return "node_modules Directories"
        }
    }

    public var systemImage: String {
        switch self {
        case .ruleMatches: return "wand.and.stars"
        case .archivedOriginals: return "checkmark.shield"
        case .userFiles: return "doc.badge.clock"
        case .caches: return "tray.full"
        case .dockerArtifacts: return "shippingbox.circle"
        case .nodeModules: return "folder.badge.gearshape"
        }
    }
}

/// A user-defined rule targeting a specific folder to recursively find and propose matching files for cleanup (DEC-011).
public struct CleanupRule: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var folderPath: String
    public var includeSubdirectories: Bool
    public var skipHiddenFiles: Bool
    /// File categories to match (OR'd with customExtensions when either is non-empty).
    public var fileCategories: [FileCategory]
    /// Specific extensions without leading dot (e.g. ["zip", "mp4", "log"]).
    public var customExtensions: [String]
    public var fileNameMatchMode: FileNameMatchMode
    public var fileNamePattern: String
    /// Optional minimum age in days (nil = any age).
    public var olderThanDays: Int?
    /// Optional minimum allocated file size in bytes (0 = any size).
    public var minimumSizeBytes: Int64

    public init(
        id: UUID = UUID(),
        name: String,
        folderPath: String,
        includeSubdirectories: Bool = true,
        skipHiddenFiles: Bool = true,
        fileCategories: [FileCategory] = [],
        customExtensions: [String] = [],
        fileNameMatchMode: FileNameMatchMode = .any,
        fileNamePattern: String = "",
        olderThanDays: Int? = nil,
        minimumSizeBytes: Int64 = 0
    ) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.includeSubdirectories = includeSubdirectories
        self.skipHiddenFiles = skipHiddenFiles
        self.fileCategories = fileCategories
        self.customExtensions = customExtensions.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
        }.filter { !$0.isEmpty }
        self.fileNameMatchMode = fileNameMatchMode
        self.fileNamePattern = fileNamePattern
        self.olderThanDays = olderThanDays.flatMap { $0 > 0 ? $0 : nil }
        self.minimumSizeBytes = max(0, minimumSizeBytes)
    }

    /// True if the rule defines at least one narrowing criterion (preventing accidental "delete everything in folder" rules).
    public var hasCriteria: Bool {
        !fileCategories.isEmpty
            || !customExtensions.isEmpty
            || (fileNameMatchMode != .any && !fileNamePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || olderThanDays != nil
            || minimumSizeBytes > 0
    }

    public var summaryDescription: String {
        var parts: [String] = []
        if !fileCategories.isEmpty {
            parts.append(fileCategories.map(\.displayName).joined(separator: ", "))
        }
        if !customExtensions.isEmpty {
            parts.append(customExtensions.map { ".\($0)" }.joined(separator: ", "))
        }
        if fileNameMatchMode != .any && !fileNamePattern.isEmpty {
            parts.append("\(fileNameMatchMode.displayName) '\(fileNamePattern)'")
        }
        if let days = olderThanDays {
            parts.append("Older than \(days)d")
        }
        if minimumSizeBytes > 0 {
            parts.append(">= \(ByteFormatting.string(from: minimumSizeBytes))")
        }
        return parts.isEmpty ? "No filter criteria" : parts.joined(separator: " • ")
    }
}

/// Specific kind of reclaimable Docker resource.
public enum DockerArtifactKind: String, Codable, Sendable {
    case unusedImage
    case stoppedContainer
    case danglingVolume
    case buildCache

    public var displayName: String {
        switch self {
        case .unusedImage: return "Unused Docker Image"
        case .stoppedContainer: return "Stopped Container"
        case .danglingVolume: return "Dangling Volume"
        case .buildCache: return "Docker Build Cache"
        }
    }
}

/// Deletion mechanics chosen by the user in the confirmation dialog (DEC-006).
public enum DeletionMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case moveToTrash
    case permanentDelete

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .moveToTrash: return "Move to Trash (Recommended)"
        case .permanentDelete: return "Delete Permanently"
        }
    }

    public var description: String {
        switch self {
        case .moveToTrash:
            return "Files and folders are moved to macOS Trash and can be recovered. Docker artifacts are removed via Docker CLI."
        case .permanentDelete:
            return "Files and folders are permanently removed immediately to reclaim space right away. This cannot be undone."
        }
    }
}

/// A single cleanup opportunity proposed to the user for review and confirmation (REQ-006).
public struct CleanupCandidate: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let category: CleanupCategory
    public let title: String
    public let location: String
    public let estimatedReclaimableBytes: Int64
    public let reason: String
    public let lastModified: Date?
    public let isDirectory: Bool
    public let verifiedArchiveRecord: VerifiedArchiveRecord?
    public let dockerArtifactKind: DockerArtifactKind?
    public let dockerObjectID: String?
    /// Captured at proposal generation time to revalidate before deletion (plan I-9).
    public let snapshotFileSize: Int64?
    public let snapshotModifiedDate: Date?

    public init(
        id: String,
        category: CleanupCategory,
        title: String,
        location: String,
        estimatedReclaimableBytes: Int64,
        reason: String,
        lastModified: Date? = nil,
        isDirectory: Bool = false,
        verifiedArchiveRecord: VerifiedArchiveRecord? = nil,
        dockerArtifactKind: DockerArtifactKind? = nil,
        dockerObjectID: String? = nil,
        snapshotFileSize: Int64? = nil,
        snapshotModifiedDate: Date? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.location = location
        self.estimatedReclaimableBytes = max(0, estimatedReclaimableBytes)
        self.reason = reason
        self.lastModified = lastModified
        self.isDirectory = isDirectory
        self.verifiedArchiveRecord = verifiedArchiveRecord
        self.dockerArtifactKind = dockerArtifactKind
        self.dockerObjectID = dockerObjectID
        self.snapshotFileSize = snapshotFileSize
        self.snapshotModifiedDate = snapshotModifiedDate
    }

    public var isDockerArtifact: Bool {
        category == .dockerArtifacts && dockerArtifactKind != nil
    }
}

/// Read-only cleanup proposal generated by CleanupScanner without mutating any data (DEC-003, I-8).
public struct CleanupProposal: Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let candidates: [CleanupCandidate]
    public let notes: [String]
    public let dockerStatusMessage: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        candidates: [CleanupCandidate],
        notes: [String] = [],
        dockerStatusMessage: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.candidates = candidates
        self.notes = notes
        self.dockerStatusMessage = dockerStatusMessage
    }

    public var totalEstimatedReclaimableBytes: Int64 {
        candidates.reduce(0) { $0 + $1.estimatedReclaimableBytes }
    }

    public func candidates(in category: CleanupCategory) -> [CleanupCandidate] {
        candidates.filter { $0.category == category }
    }
}

/// Explicit user confirmation token required by CleanupExecutor before any deletion can run (DEC-003, I-9).
public struct CleanupConfirmation: Sendable {
    public let proposalID: UUID
    public let confirmedCandidateIDs: Set<String>
    public let deletionMode: DeletionMode
    public let confirmedAt: Date

    public init(
        proposalID: UUID,
        confirmedCandidateIDs: Set<String>,
        deletionMode: DeletionMode = .moveToTrash,
        confirmedAt: Date = Date()
    ) {
        self.proposalID = proposalID
        self.confirmedCandidateIDs = confirmedCandidateIDs
        self.deletionMode = deletionMode
        self.confirmedAt = confirmedAt
    }
}

/// Outcome of attempting to delete one confirmed cleanup candidate.
public struct CleanupItemResult: Identifiable, Hashable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case deletedToTrash
        case deletedPermanently
        case deletedViaDocker
        case skippedRevalidationFailed
        case failed
    }

    public let id: String
    public let title: String
    public let location: String
    public let category: CleanupCategory
    public let status: Status
    public let reclaimedBytes: Int64
    public let detail: String

    public init(
        id: String,
        title: String,
        location: String,
        category: CleanupCategory,
        status: Status,
        reclaimedBytes: Int64,
        detail: String
    ) {
        self.id = id
        self.title = title
        self.location = location
        self.category = category
        self.status = status
        self.reclaimedBytes = max(0, reclaimedBytes)
        self.detail = detail
    }

    public var didDelete: Bool {
        switch status {
        case .deletedToTrash, .deletedPermanently, .deletedViaDocker:
            return true
        case .skippedRevalidationFailed, .failed:
            return false
        }
    }
}

/// Aggregate result of executing a user-confirmed cleanup operation.
public struct CleanupExecutionResult: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let executedAt: Date
    public let deletionMode: DeletionMode
    public let itemResults: [CleanupItemResult]

    public init(
        id: UUID = UUID(),
        executedAt: Date = Date(),
        deletionMode: DeletionMode,
        itemResults: [CleanupItemResult]
    ) {
        self.id = id
        self.executedAt = executedAt
        self.deletionMode = deletionMode
        self.itemResults = itemResults
    }

    public var succeededCount: Int { itemResults.filter(\.didDelete).count }
    public var skippedCount: Int { itemResults.filter { $0.status == .skippedRevalidationFailed }.count }
    public var failedCount: Int { itemResults.filter { $0.status == .failed }.count }
    public var totalReclaimedBytes: Int64 { itemResults.filter(\.didDelete).reduce(0) { $0 + $1.reclaimedBytes } }
}
