import Foundation

/// A scheduled or resumed archive job ready to be executed immediately.
public struct ScheduledRunRequest: Hashable, Sendable {
    public let jobID: UUID
    public let trigger: ArchiveTrigger

    public init(jobID: UUID, trigger: ArchiveTrigger) {
        self.jobID = jobID
        self.trigger = trigger
    }
}

/// Output of evaluating schedules and deferred pending archive runs.
public struct ScheduleEvaluation: Sendable {
    public let readyRuns: [ScheduledRunRequest]
    public let updatedPendingRuns: [PendingArchiveRun]

    public init(readyRuns: [ScheduledRunRequest], updatedPendingRuns: [PendingArchiveRun]) {
        self.readyRuns = readyRuns
        self.updatedPendingRuns = updatedPendingRuns
    }
}

/// Coordinates scheduled archiving, missed-run consolidation, overlap protection, and automatic
/// resumption of deferred runs when a disconnected destination volume mounts (REQ-005, DEC-004, plan I-7).
public final class ArchiveScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlightJobIDs: Set<UUID> = []

    public init() {}

    /// Attempts to mark a job as currently executing; returns false if already running (prevents overlapping runs).
    public func beginRun(for jobID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if inFlightJobIDs.contains(jobID) {
            return false
        }
        inFlightJobIDs.insert(jobID)
        return true
    }

    /// Marks a job execution as finished.
    public func endRun(for jobID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        inFlightJobIDs.remove(jobID)
    }

    public func isRunning(_ jobID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlightJobIDs.contains(jobID)
    }

    /// Evaluates due schedules and existing deferred runs at `now`:
    /// - Skips jobs already in flight.
    /// - Resumes pending deferred runs whose required destination volumes are now mounted.
    /// - Consolidates repeated missed runs for the same unavailable job into a single PendingArchiveRun.
    public func evaluate(
        jobs: [ArchiveJob],
        pendingRuns: [PendingArchiveRun],
        now: Date = Date(),
        mountedVolumePaths: Set<String>? = nil,
        calendar: Calendar = .current
    ) -> ScheduleEvaluation {
        lock.lock()
        let activeIDs = inFlightJobIDs
        lock.unlock()

        var pendingByJobID = Dictionary(uniqueKeysWithValues: pendingRuns.map { ($0.jobID, $0) })
        let jobsByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        var readyRuns: [ScheduledRunRequest] = []
        var scheduledJobIDs: Set<UUID> = []

        // Drop pending entries whose job was deleted.
        for pendingJobID in Array(pendingByJobID.keys) where jobsByID[pendingJobID] == nil {
            pendingByJobID.removeValue(forKey: pendingJobID)
        }

        // 1. Check existing deferred pending runs first for automatic resumption (DEC-004).
        for (jobID, pending) in pendingByJobID {
            guard !activeIDs.contains(jobID), let job = jobsByID[jobID] else { continue }
            let missing = missingDestinations(for: job, mountedVolumePaths: mountedVolumePaths)
            if missing.isEmpty {
                pendingByJobID.removeValue(forKey: jobID)
                readyRuns.append(ScheduledRunRequest(jobID: jobID, trigger: .resumedDeferred))
                scheduledJobIDs.insert(jobID)
            } else {
                // Keep pending; update missed count if another schedule interval also elapsed.
                var updated = pending
                updated.missingDestinationPaths = missing
                updated.requiredVolumeRoots = Array(Set(missing.map { VolumeMonitor.volumeRootPath(forDestination: $0) })).sorted()
                if job.schedule.isDue(lastRun: updated.latestMissedAt, createdAt: job.createdAt, now: now, calendar: calendar) {
                    updated.missedRunCount += 1
                    updated.latestMissedAt = now
                }
                pendingByJobID[jobID] = updated
                // Already handled in this evaluation pass; do not double-count in the newly-due loop.
                scheduledJobIDs.insert(jobID)
            }
        }

        // 2. Check all enabled scheduled jobs for newly due runs.
        for job in jobs {
            guard !activeIDs.contains(job.id), !scheduledJobIDs.contains(job.id) else { continue }
            guard job.schedule.isDue(lastRun: job.lastRunAt, createdAt: job.createdAt, now: now, calendar: calendar) else {
                continue
            }

            let missing = missingDestinations(for: job, mountedVolumePaths: mountedVolumePaths)
            if missing.isEmpty {
                readyRuns.append(ScheduledRunRequest(jobID: job.id, trigger: .scheduled))
                scheduledJobIDs.insert(job.id)
            } else {
                // Destination disk unavailable: queue or consolidate into existing PendingArchiveRun (plan I-7).
                let requiredRoots = Array(Set(missing.map { VolumeMonitor.volumeRootPath(forDestination: $0) })).sorted()
                if var existing = pendingByJobID[job.id] {
                    existing.missedRunCount += 1
                    existing.latestMissedAt = now
                    existing.missingDestinationPaths = missing
                    existing.requiredVolumeRoots = requiredRoots
                    pendingByJobID[job.id] = existing
                } else {
                    pendingByJobID[job.id] = PendingArchiveRun(
                        jobID: job.id,
                        jobName: job.name,
                        firstScheduledAt: now,
                        latestMissedAt: now,
                        missedRunCount: 1,
                        missingDestinationPaths: missing,
                        requiredVolumeRoots: requiredRoots
                    )
                }
            }
        }

        let orderedPending = pendingByJobID.values.sorted { $0.firstScheduledAt < $1.firstScheduledAt }
        return ScheduleEvaluation(readyRuns: readyRuns, updatedPendingRuns: orderedPending)
    }

    /// Evaluates immediately when a volume connects to resume any pending runs waiting for it.
    public func handleVolumeMounted(
        volumePath: String,
        jobs: [ArchiveJob],
        pendingRuns: [PendingArchiveRun],
        mountedVolumePaths: Set<String>? = nil
    ) -> ScheduleEvaluation {
        let normalizedMount = URL(fileURLWithPath: volumePath).standardizedFileURL.path
        var effectiveMounted = mountedVolumePaths
        if effectiveMounted != nil {
            effectiveMounted?.insert(normalizedMount)
        }
        return evaluate(
            jobs: jobs,
            pendingRuns: pendingRuns,
            now: Date(),
            mountedVolumePaths: effectiveMounted
        )
    }

    /// Returns destination paths configured in `job` whose hosting volume is currently unavailable.
    public func missingDestinations(
        for job: ArchiveJob,
        mountedVolumePaths: Set<String>? = nil
    ) -> [String] {
        job.configuredDestinations.filter { dest in
            !VolumeMonitor.isDestinationVolumeAvailable(dest, mountedVolumePaths: mountedVolumePaths)
        }
    }
}
