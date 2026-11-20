import Foundation
import XCTest
@testable import DiskStewardCore

final class ArchiveSchedulerTests: XCTestCase {
    func testDefersWhenDestinationUnavailableConsolidatesMissedRunsAndResumesOnMount() {
        let scheduler = ArchiveScheduler()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        let job = ArchiveJob(
            name: "Downloads Archive",
            sourceFolders: ["/Users/boris/Downloads"],
            rules: [
                ArchiveRule(
                    name: "Movies",
                    fileCategories: [.videos],
                    destinationFolderPath: "/Volumes/ExternalBackup/Movies"
                )
            ],
            schedule: ArchiveSchedule(isEnabled: true, frequency: .hourly),
            createdAt: createdAt,
            lastRunAt: nil
        )

        // Before 1 hour elapses: not due yet.
        let tBefore = createdAt.addingTimeInterval(1800)
        let eval0 = scheduler.evaluate(jobs: [job], pendingRuns: [], now: tBefore, mountedVolumePaths: ["/"])
        XCTAssertTrue(eval0.readyRuns.isEmpty)
        XCTAssertTrue(eval0.updatedPendingRuns.isEmpty)

        // At +1 hour while ExternalBackup is disconnected -> queued as 1 PendingArchiveRun.
        let t1 = createdAt.addingTimeInterval(3600)
        let eval1 = scheduler.evaluate(jobs: [job], pendingRuns: [], now: t1, mountedVolumePaths: ["/"])
        XCTAssertTrue(eval1.readyRuns.isEmpty)
        XCTAssertEqual(eval1.updatedPendingRuns.count, 1)
        XCTAssertEqual(eval1.updatedPendingRuns[0].missedRunCount, 1)
        XCTAssertEqual(eval1.updatedPendingRuns[0].requiredVolumeRoots, ["/Volumes/ExternalBackup"])

        // At +2 hours still disconnected -> consolidated into the SAME PendingArchiveRun (missedRunCount == 2).
        let t2 = t1.addingTimeInterval(3600)
        let eval2 = scheduler.evaluate(
            jobs: [job],
            pendingRuns: eval1.updatedPendingRuns,
            now: t2,
            mountedVolumePaths: ["/"]
        )
        XCTAssertTrue(eval2.readyRuns.isEmpty)
        XCTAssertEqual(eval2.updatedPendingRuns.count, 1)
        XCTAssertEqual(eval2.updatedPendingRuns[0].missedRunCount, 2)

        // ExternalBackup mounts -> automatically resumes as `.resumedDeferred` and clears pending entry!
        let eval3 = scheduler.handleVolumeMounted(
            volumePath: "/Volumes/ExternalBackup",
            jobs: [job],
            pendingRuns: eval2.updatedPendingRuns,
            mountedVolumePaths: ["/"]
        )
        XCTAssertEqual(eval3.readyRuns.count, 1)
        XCTAssertEqual(eval3.readyRuns[0].jobID, job.id)
        XCTAssertEqual(eval3.readyRuns[0].trigger, .resumedDeferred)
        XCTAssertTrue(eval3.updatedPendingRuns.isEmpty)
    }

    func testOverlapProtectionPreventsConcurrentRunsOfSameJob() {
        let scheduler = ArchiveScheduler()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let job = ArchiveJob(
            name: "Hourly Local",
            sourceFolders: ["/Users/boris/Downloads"],
            rules: [ArchiveRule(name: "All", destinationFolderPath: "/Users/boris/Archive")],
            schedule: ArchiveSchedule(isEnabled: true, frequency: .hourly),
            createdAt: createdAt
        )

        XCTAssertTrue(scheduler.beginRun(for: job.id))
        XCTAssertFalse(scheduler.beginRun(for: job.id), "Second concurrent beginRun must be rejected")

        let dueTime = createdAt.addingTimeInterval(7200)
        let evalWhileRunning = scheduler.evaluate(jobs: [job], pendingRuns: [], now: dueTime, mountedVolumePaths: ["/"])
        XCTAssertTrue(evalWhileRunning.readyRuns.isEmpty, "In-flight job must not be scheduled concurrently")

        scheduler.endRun(for: job.id)
        let evalAfterEnd = scheduler.evaluate(jobs: [job], pendingRuns: [], now: dueTime, mountedVolumePaths: ["/"])
        XCTAssertEqual(evalAfterEnd.readyRuns.count, 1)
        XCTAssertEqual(evalAfterEnd.readyRuns[0].trigger, .scheduled)
    }
}
