import Foundation

/// Injectable file deletion backend for safe testing of Trash vs Permanent Delete mechanics (DEC-006).
public protocol FileDeleter: Sendable {
    func moveToTrash(url: URL) throws -> URL?
    func deletePermanently(url: URL) throws
}

/// Default macOS FileManager implementation supporting Trash (recoverable) and Permanent deletion.
public struct SystemFileDeleter: FileDeleter {
    public init() {}

    public func moveToTrash(url: URL) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    public func deletePermanently(url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// Executes user-confirmed cleanup proposals and archived-original removals with mandatory
/// pre-deletion revalidation and partial-failure reporting (REQ-005, REQ-006, DEC-003, DEC-006, DEC-007, plan I-9).
public struct CleanupExecutor: Sendable {
    private let fileDeleter: FileDeleter
    private let dockerInspector: DockerInspector
    private let protectedRoots: Set<String>

    public init(
        fileDeleter: FileDeleter = SystemFileDeleter(),
        dockerInspector: DockerInspector = DockerInspector(),
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.fileDeleter = fileDeleter
        self.dockerInspector = dockerInspector
        self.protectedRoots = [
            "/",
            "/System",
            "/Library",
            "/Applications",
            "/Users",
            "/Volumes",
            "/bin",
            "/sbin",
            "/usr",
            "/etc",
            "/var",
            URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        ]
    }

    /// Executes deletion ONLY for candidates explicitly confirmed in `confirmation` matching `proposal.id`.
    /// Passing an empty `confirmedCandidateIDs` or a mismatched `proposalID` deletes nothing.
    public func execute(
        proposal: CleanupProposal,
        confirmation: CleanupConfirmation
    ) async -> CleanupExecutionResult {
        guard confirmation.proposalID == proposal.id, !confirmation.confirmedCandidateIDs.isEmpty else {
            return CleanupExecutionResult(
                executedAt: Date(),
                deletionMode: confirmation.deletionMode,
                itemResults: []
            )
        }

        let selectedCandidates = proposal.candidates.filter { confirmation.confirmedCandidateIDs.contains($0.id) }
        var results: [CleanupItemResult] = []
        results.reserveCapacity(selectedCandidates.count)

        for candidate in selectedCandidates {
            if candidate.isDockerArtifact {
                let dockerRes = await dockerInspector.removeArtifact(candidate)
                results.append(dockerRes)
            } else {
                let fileRes = executeFilesystemDeletion(candidate: candidate, mode: confirmation.deletionMode)
                results.append(fileRes)
            }
        }

        return CleanupExecutionResult(
            executedAt: Date(),
            deletionMode: confirmation.deletionMode,
            itemResults: results
        )
    }

    private func executeFilesystemDeletion(
        candidate: CleanupCandidate,
        mode: DeletionMode
    ) -> CleanupItemResult {
        let fm = FileManager.default
        let targetURL = URL(fileURLWithPath: candidate.location).standardizedFileURL
        let stdPath = targetURL.path

        // 1. Safety guard against protected system roots.
        if protectedRoots.contains(stdPath) {
            return CleanupItemResult(
                id: candidate.id,
                title: candidate.title,
                location: candidate.location,
                category: candidate.category,
                status: .skippedRevalidationFailed,
                reclaimedBytes: 0,
                detail: "Refused to delete protected system or root directory"
            )
        }

        // 2. Revalidate existence right before execution (plan I-9).
        guard fm.fileExists(atPath: stdPath) else {
            return CleanupItemResult(
                id: candidate.id,
                title: candidate.title,
                location: candidate.location,
                category: candidate.category,
                status: .skippedRevalidationFailed,
                reclaimedBytes: 0,
                detail: "Item no longer exists at its proposed path"
            )
        }

        // 3. Revalidate regular file metadata (size & modification timestamp) so confirmation applies to unchanged data.
        if !candidate.isDirectory,
           let expectedSize = candidate.snapshotFileSize,
           let expectedMod = candidate.snapshotModifiedDate {
            do {
                let values = try targetURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let currentSize = Int64(values.fileSize ?? -1)
                let currentMod = values.contentModificationDate
                if currentSize != expectedSize || (currentMod != nil && abs(currentMod!.timeIntervalSince(expectedMod)) > 1.0) {
                    return CleanupItemResult(
                        id: candidate.id,
                        title: candidate.title,
                        location: candidate.location,
                        category: candidate.category,
                        status: .skippedRevalidationFailed,
                        reclaimedBytes: 0,
                        detail: "File changed after proposal was reviewed; skipped to protect modified data"
                    )
                }
            } catch {
                return CleanupItemResult(
                    id: candidate.id,
                    title: candidate.title,
                    location: candidate.location,
                    category: candidate.category,
                    status: .skippedRevalidationFailed,
                    reclaimedBytes: 0,
                    detail: "Unable to revalidate file metadata: \(error.localizedDescription)"
                )
            }
        }

        // 4. For archived originals, re-verify destination archive copy still exists and matches SHA-256 (DEC-007, plan I-9).
        if candidate.category == .archivedOriginals {
            guard let record = candidate.verifiedArchiveRecord else {
                return CleanupItemResult(
                    id: candidate.id,
                    title: candidate.title,
                    location: candidate.location,
                    category: candidate.category,
                    status: .skippedRevalidationFailed,
                    reclaimedBytes: 0,
                    detail: "Missing verified archive record; refused to remove original"
                )
            }
            let archiveURL = URL(fileURLWithPath: record.destinationPath)
            guard fm.fileExists(atPath: archiveURL.path) else {
                return CleanupItemResult(
                    id: candidate.id,
                    title: candidate.title,
                    location: candidate.location,
                    category: candidate.category,
                    status: .skippedRevalidationFailed,
                    reclaimedBytes: 0,
                    detail: "Archived copy is currently unavailable at \(record.destinationPath); original preserved"
                )
            }
            do {
                let archiveHash = try FileHasher.sha256(of: archiveURL)
                let sourceHash = try FileHasher.sha256(of: targetURL)
                guard archiveHash == record.sha256 && sourceHash == record.sha256 else {
                    return CleanupItemResult(
                        id: candidate.id,
                        title: candidate.title,
                        location: candidate.location,
                        category: candidate.category,
                        status: .skippedRevalidationFailed,
                        reclaimedBytes: 0,
                        detail: "SHA-256 verification mismatch between original and archive copy; original preserved"
                    )
                }
            } catch {
                return CleanupItemResult(
                    id: candidate.id,
                    title: candidate.title,
                    location: candidate.location,
                    category: candidate.category,
                    status: .skippedRevalidationFailed,
                    reclaimedBytes: 0,
                    detail: "Failed to verify archive SHA-256 before removing original: \(error.localizedDescription)"
                )
            }
        }

        // 5. Perform confirmed deletion (DEC-006: Move to Trash default; Permanent Delete when explicitly chosen).
        do {
            switch mode {
            case .moveToTrash:
                let trashedURL = try fileDeleter.moveToTrash(url: targetURL)
                let note = trashedURL.map { "Moved to Trash (\($0.lastPathComponent))" } ?? "Moved to Trash"
                return CleanupItemResult(
                    id: candidate.id,
                    title: candidate.title,
                    location: candidate.location,
                    category: candidate.category,
                    status: .deletedToTrash,
                    reclaimedBytes: candidate.estimatedReclaimableBytes,
                    detail: note
                )
            case .permanentDelete:
                try fileDeleter.deletePermanently(url: targetURL)
                return CleanupItemResult(
                    id: candidate.id,
                    title: candidate.title,
                    location: candidate.location,
                    category: candidate.category,
                    status: .deletedPermanently,
                    reclaimedBytes: candidate.estimatedReclaimableBytes,
                    detail: "Deleted permanently"
                )
            }
        } catch {
            return CleanupItemResult(
                id: candidate.id,
                title: candidate.title,
                location: candidate.location,
                category: candidate.category,
                status: .failed,
                reclaimedBytes: 0,
                detail: error.localizedDescription
            )
        }
    }
}
