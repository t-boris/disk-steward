import Foundation
import XCTest
@testable import DiskStewardCore

final class ConfigurationStoreAndScheduleTests: XCTestCase {
    func testPersistedAppStateRoundTripsCleanly() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskStewardConfigTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ConfigurationStore(directoryURL: tempDir)
        let job = ArchiveJob(
            name: "Downloads Daily",
            sourceFolders: ["/Users/test/Downloads"],
            rules: ArchiveRuleEngine.starterRules(destinationRoot: "/Volumes/Storage0/Archive"),
            fallbackDestinationPath: "/Volumes/Storage0/Archive/Unsorted",
            schedule: ArchiveSchedule(isEnabled: true, frequency: .daily, hour: 3, minute: 30)
        )
        let pending = PendingArchiveRun(
            jobID: job.id,
            jobName: job.name,
            firstScheduledAt: Date(timeIntervalSince1970: 1_750_000_000),
            missedRunCount: 2,
            missingDestinationPaths: ["/Volumes/Storage0/Archive/Pictures"],
            requiredVolumeRoots: ["/Volumes/Storage0"]
        )
        let verified = VerifiedArchiveRecord(
            jobID: job.id,
            sourcePath: "/Users/test/Downloads/a.jpg",
            destinationPath: "/Volumes/Storage0/Archive/Pictures/a.jpg",
            sha256: "abcdef0123456789",
            fileSize: 4096,
            sourceModifiedDate: Date(timeIntervalSince1970: 1_749_000_000)
        )

        let state = PersistedAppState(
            configuration: AppConfiguration(volumeRefreshIntervalSeconds: 60, archiveJobs: [job]),
            pendingArchiveRuns: [pending],
            verifiedArchives: [verified]
        )

        try store.save(state)
        let loaded = store.load()

        XCTAssertEqual(loaded.configuration.volumeRefreshIntervalSeconds, 60)
        XCTAssertEqual(loaded.configuration.archiveJobs.count, 1)
        XCTAssertEqual(loaded.configuration.archiveJobs[0].name, "Downloads Daily")
        XCTAssertEqual(loaded.configuration.archiveJobs[0].rules.count, 5)
        XCTAssertEqual(loaded.pendingArchiveRuns.count, 1)
        XCTAssertEqual(loaded.pendingArchiveRuns[0].missedRunCount, 2)
        XCTAssertEqual(loaded.verifiedArchives.count, 1)
        XCTAssertEqual(loaded.verifiedArchives[0].sha256, "abcdef0123456789")
    }

    func testDailyAndWeeklySchedulesComputeNextRunAndDueState() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let baseline = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 1, minute: 0))!
        let daily = ArchiveSchedule(isEnabled: true, frequency: .daily, hour: 2, minute: 30)

        let nextDaily = daily.nextRunDate(after: baseline, calendar: calendar)
        XCTAssertEqual(nextDaily, calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 2, minute: 30))!)
        XCTAssertFalse(daily.isDue(lastRun: baseline, createdAt: baseline, now: baseline.addingTimeInterval(3600), calendar: calendar))
        XCTAssertTrue(daily.isDue(lastRun: baseline, createdAt: baseline, now: baseline.addingTimeInterval(5400), calendar: calendar))

        let manual = ArchiveSchedule(isEnabled: false, frequency: .manual)
        XCTAssertNil(manual.nextRunDate(after: baseline, calendar: calendar))
        XCTAssertFalse(manual.isDue(lastRun: nil, createdAt: baseline, now: baseline.addingTimeInterval(99_999), calendar: calendar))
    }

    func testGlobPatternMatchingForArchiveRules() {
        XCTAssertTrue(ArchiveRuleEngine.matchesGlob(text: "screenshot-2026-11-19.png", pattern: "screenshot*"))
        XCTAssertTrue(ArchiveRuleEngine.matchesGlob(text: "invoice_04.pdf", pattern: "invoice_??.pdf"))
        XCTAssertFalse(ArchiveRuleEngine.matchesGlob(text: "invoice_104.pdf", pattern: "invoice_??.pdf"))
        XCTAssertTrue(ArchiveRuleEngine.matchesGlob(text: "app.dmg", pattern: "*.dmg"))
        XCTAssertFalse(ArchiveRuleEngine.matchesGlob(text: "app.dmg.zip", pattern: "*.dmg"))
    }
}
