import Foundation

/// Output returned after running an archive job: the run summary plus newly verified SHA-256 archive records.
public struct ArchiveExecutionOutput: Sendable {
    public let report: ArchiveRunReport
    public let verifiedRecords: [VerifiedArchiveRecord]

    public init(report: ArchiveRunReport, verifiedRecords: [VerifiedArchiveRecord]) {
        self.report = report
        self.verifiedRecords = verifiedRecords
    }
}

/// Progress update emitted during an active archive execution.
public struct ArchiveProgress: Sendable {
    public let jobID: UUID
    public let currentFileName: String
    public let completedItems: Int
    public let totalItems: Int
    public let bytesCopied: Int64

    public init(jobID: UUID, currentFileName: String, completedItems: Int, totalItems: Int, bytesCopied: Int64) {
        self.jobID = jobID
        self.currentFileName = currentFileName
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.bytesCopied = bytesCopied
    }
}

/// Executes classified archiving by copying files safely with SHA-256 verification and
/// non-destructive collision handling while strictly retaining originals (REQ-005, DEC-002, DEC-003, DEC-007, plan I-6).
public struct ArchiveExecutor: Sendable {
    private let ruleEngine: ArchiveRuleEngine
    public let maxRetriesOnSourceChange: Int

    public init(ruleEngine: ArchiveRuleEngine = ArchiveRuleEngine(), maxRetriesOnSourceChange: Int = 1) {
        self.ruleEngine = ruleEngine
        self.maxRetriesOnSourceChange = max(0, maxRetriesOnSourceChange)
    }

    /// Executes `job` without EVER deleting any source original.
    /// If any required destination volume is unavailable, returns a deferred report instead of failing destructively.
    public func execute(
        job: ArchiveJob,
        trigger: ArchiveTrigger,
        mountedVolumePaths: Set<String>? = nil,
        progressHandler: (@Sendable (ArchiveProgress) -> Void)? = nil
    ) async -> ArchiveExecutionOutput {
        let startedAt = Date()
        let plan = ruleEngine.buildPlan(for: job, mountedVolumePaths: mountedVolumePaths)

        // If any destination disk needed by this job is currently disconnected, defer cleanly (DEC-004).
        if !plan.unavailableDestinations.isEmpty {
            let unavailableOutcomes = plan.entries
                .filter { $0.action == .destinationUnavailable }
                .map {
                    ArchiveItemOutcome(
                        sourcePath: $0.sourcePath,
                        destinationPath: $0.destinationPath,
                        kind: .destinationUnavailable,
                        detail: "Destination volume is unavailable"
                    )
                }

            let report = ArchiveRunReport(
                jobID: job.id,
                jobName: job.name,
                trigger: trigger,
                startedAt: startedAt,
                finishedAt: Date(),
                status: .deferredDestinationUnavailable,
                unavailableDestinations: plan.unavailableDestinations,
                outcomes: unavailableOutcomes
            )
            return ArchiveExecutionOutput(report: report, verifiedRecords: [])
        }

        var outcomes: [ArchiveItemOutcome] = []
        var verifiedRecords: [VerifiedArchiveRecord] = []
        var claimedDestinations: [String: String] = [:]

        var copiedCount = 0
        var renamedCount = 0
        var duplicateCount = 0
        var unmatchedCount = 0
        var sourceChangedCount = 0
        var failedCount = 0
        var interruptedCount = 0
        var totalBytesCopied: Int64 = 0

        let fm = FileManager.default
        let totalEntries = plan.entries.count

        for (index, entry) in plan.entries.enumerated() {
            if Task.isCancelled {
                interruptedCount += 1
                outcomes.append(
                    ArchiveItemOutcome(
                        sourcePath: entry.sourcePath,
                        destinationPath: entry.destinationPath,
                        kind: .interrupted,
                        detail: "Archive run was cancelled before copying this file"
                    )
                )
                continue
            }

            if entry.action == .skipUnmatched {
                unmatchedCount += 1
                outcomes.append(
                    ArchiveItemOutcome(
                        sourcePath: entry.sourcePath,
                        destinationPath: nil,
                        kind: .skippedUnmatched,
                        detail: entry.note
                    )
                )
                continue
            }

            guard let plannedDestPath = entry.destinationPath else {
                failedCount += 1
                outcomes.append(
                    ArchiveItemOutcome(
                        sourcePath: entry.sourcePath,
                        destinationPath: nil,
                        kind: .failed,
                        detail: "Missing destination path"
                    )
                )
                continue
            }

            progressHandler?(
                ArchiveProgress(
                    jobID: job.id,
                    currentFileName: entry.fileName,
                    completedItems: index,
                    totalItems: totalEntries,
                    bytesCopied: totalBytesCopied
                )
            )

            let sourceURL = URL(fileURLWithPath: entry.sourcePath)
            let plannedURL = URL(fileURLWithPath: plannedDestPath)
            // Always resolve live collisions starting from the base filename inside the target directory,
            // so duplicate detection and rename reporting (.copiedRenamed) remain accurate at copy time.
            let baseDesiredDestURL = plannedURL
                .deletingLastPathComponent()
                .appendingPathComponent(entry.fileName)

            let copyOutcome = copySingleFileWithVerification(
                jobID: job.id,
                sourceURL: sourceURL,
                desiredDestURL: baseDesiredDestURL,
                claimedDestinations: &claimedDestinations,
                fileManager: fm
            )

            outcomes.append(copyOutcome.outcome)
            if let record = copyOutcome.verifiedRecord {
                verifiedRecords.append(record)
            }

            switch copyOutcome.outcome.kind {
            case .copied:
                copiedCount += 1
                totalBytesCopied += copyOutcome.outcome.bytesCopied
            case .copiedRenamed:
                renamedCount += 1
                totalBytesCopied += copyOutcome.outcome.bytesCopied
            case .skippedDuplicate:
                duplicateCount += 1
            case .skippedUnmatched:
                unmatchedCount += 1
            case .skippedSourceChanged:
                sourceChangedCount += 1
            case .failed:
                failedCount += 1
            case .interrupted:
                interruptedCount += 1
            case .destinationUnavailable:
                failedCount += 1
            }
        }

        let status: ArchiveRunStatus
        if interruptedCount > 0 || Task.isCancelled {
            status = .cancelled
        } else if failedCount > 0 || sourceChangedCount > 0 || !plan.scanErrors.isEmpty {
            status = .completedWithErrors
        } else {
            status = .completed
        }

        let report = ArchiveRunReport(
            jobID: job.id,
            jobName: job.name,
            trigger: trigger,
            startedAt: startedAt,
            finishedAt: Date(),
            status: status,
            copiedCount: copiedCount,
            renamedCount: renamedCount,
            duplicateCount: duplicateCount,
            unmatchedCount: unmatchedCount,
            sourceChangedCount: sourceChangedCount,
            failedCount: failedCount,
            interruptedCount: interruptedCount,
            bytesCopied: totalBytesCopied,
            unavailableDestinations: [],
            outcomes: outcomes
        )

        return ArchiveExecutionOutput(report: report, verifiedRecords: verifiedRecords)
    }

    private struct SingleFileResult {
        let outcome: ArchiveItemOutcome
        let verifiedRecord: VerifiedArchiveRecord?
    }

    private func copySingleFileWithVerification(
        jobID: UUID,
        sourceURL: URL,
        desiredDestURL: URL,
        claimedDestinations: inout [String: String],
        fileManager fm: FileManager
    ) -> SingleFileResult {
        var attempt = 0
        while attempt <= maxRetriesOnSourceChange {
            attempt += 1

            do {
                let beforeValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let sizeBefore = Int64(beforeValues.fileSize ?? 0)
                let modBefore = beforeValues.contentModificationDate ?? Date()

                let sourceHash = try FileHasher.sha256(of: sourceURL)

                // Re-resolve collision right at execution time with live SHA-256 (DEC-007).
                let resolution = ruleEngine.resolveDestination(
                    sourceURL: sourceURL,
                    desiredDestinationURL: desiredDestURL,
                    sourceSHA256: sourceHash,
                    claimedDestinations: &claimedDestinations
                )

                if resolution.action == .skipDuplicate {
                    let record = VerifiedArchiveRecord(
                        jobID: jobID,
                        sourcePath: sourceURL.standardizedFileURL.path,
                        destinationPath: resolution.destinationURL.standardizedFileURL.path,
                        sha256: sourceHash,
                        fileSize: sizeBefore,
                        sourceModifiedDate: modBefore
                    )
                    return SingleFileResult(
                        outcome: ArchiveItemOutcome(
                            sourcePath: sourceURL.path,
                            destinationPath: resolution.destinationURL.path,
                            kind: .skippedDuplicate,
                            bytesCopied: 0,
                            sha256: sourceHash,
                            detail: resolution.note ?? "Identical SHA-256 copy already exists"
                        ),
                        verifiedRecord: record
                    )
                }

                let finalDestURL = resolution.destinationURL
                let destDir = finalDestURL.deletingLastPathComponent()
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

                // Copy via temporary hidden file in destination directory for crash/interruption safety.
                let tempURL = destDir.appendingPathComponent(".disksteward-tmp-\(UUID().uuidString)")
                defer {
                    if fm.fileExists(atPath: tempURL.path) {
                        try? fm.removeItem(at: tempURL)
                    }
                }

                try fm.copyItem(at: sourceURL, to: tempURL)

                let destHash = try FileHasher.sha256(of: tempURL)

                // Check whether the source file changed while copying (plan I-6).
                let afterValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let sizeAfter = Int64(afterValues.fileSize ?? 0)
                let modAfter = afterValues.contentModificationDate ?? Date()

                if sizeBefore != sizeAfter || modBefore != modAfter || destHash != sourceHash {
                    try? fm.removeItem(at: tempURL)
                    if attempt <= maxRetriesOnSourceChange {
                        continue
                    }
                    return SingleFileResult(
                        outcome: ArchiveItemOutcome(
                            sourcePath: sourceURL.path,
                            destinationPath: finalDestURL.path,
                            kind: .skippedSourceChanged,
                            detail: "Source file changed during copy; skipped after retry to avoid corrupting archive"
                        ),
                        verifiedRecord: nil
                    )
                }

                // Atomically commit verified temporary file to final destination path (never overwrites).
                try fm.moveItem(at: tempURL, to: finalDestURL)
                try? fm.setAttributes([.modificationDate: modBefore], ofItemAtPath: finalDestURL.path)

                let record = VerifiedArchiveRecord(
                    jobID: jobID,
                    sourcePath: sourceURL.standardizedFileURL.path,
                    destinationPath: finalDestURL.standardizedFileURL.path,
                    sha256: destHash,
                    fileSize: sizeBefore,
                    sourceModifiedDate: modBefore
                )

                let kind: ArchiveItemOutcome.Kind = (resolution.action == .copyWithSuffix) ? .copiedRenamed : .copied
                return SingleFileResult(
                    outcome: ArchiveItemOutcome(
                        sourcePath: sourceURL.path,
                        destinationPath: finalDestURL.path,
                        kind: kind,
                        bytesCopied: sizeBefore,
                        sha256: destHash,
                        detail: resolution.note ?? "Copied and verified with SHA-256"
                    ),
                    verifiedRecord: record
                )
            } catch {
                return SingleFileResult(
                    outcome: ArchiveItemOutcome(
                        sourcePath: sourceURL.path,
                        destinationPath: desiredDestURL.path,
                        kind: .failed,
                        detail: error.localizedDescription
                    ),
                    verifiedRecord: nil
                )
            }
        }

        return SingleFileResult(
            outcome: ArchiveItemOutcome(
                sourcePath: sourceURL.path,
                destinationPath: desiredDestURL.path,
                kind: .failed,
                detail: "Copy failed after retries"
            ),
            verifiedRecord: nil
        )
    }
}
