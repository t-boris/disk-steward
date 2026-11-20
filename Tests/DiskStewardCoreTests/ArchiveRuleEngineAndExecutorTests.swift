import Foundation
import XCTest
@testable import DiskStewardCore

final class ArchiveRuleEngineAndExecutorTests: XCTestCase {
    private var rootDir: URL!
    private var downloadsDir: URL!
    private var documentsDir: URL!
    private var archiveRoot: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        rootDir = fm.temporaryDirectory.appendingPathComponent("DiskStewardArchiveTests-\(UUID().uuidString)")
        downloadsDir = rootDir.appendingPathComponent("Downloads")
        documentsDir = rootDir.appendingPathComponent("Documents")
        archiveRoot = rootDir.appendingPathComponent("Archive")
        try fm.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: documentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootDir {
            try? FileManager.default.removeItem(at: rootDir)
        }
    }

    func testRulePrecedenceFileTypeNameAndSourceFolderWithOptionalFallback() async throws {
        let pic = downloadsDir.appendingPathComponent("Screenshot-2026.png")
        let otherPic = downloadsDir.appendingPathComponent("vacation.jpg")
        let movie = downloadsDir.appendingPathComponent("clip.mp4")
        let docFromDocs = documentsDir.appendingPathComponent("tax.pdf")
        let unmatched = downloadsDir.appendingPathComponent("mystery.bin")

        try Data("screenshot-data".utf8).write(to: pic)
        try Data("vacation-data".utf8).write(to: otherPic)
        try Data("movie-data".utf8).write(to: movie)
        try Data("tax-data".utf8).write(to: docFromDocs)
        try Data("unknown-data".utf8).write(to: unmatched)

        let screenshotsDest = archiveRoot.appendingPathComponent("Screenshots").path
        let picturesDest = archiveRoot.appendingPathComponent("Pictures").path
        let moviesDest = archiveRoot.appendingPathComponent("Movies").path
        let docsDest = archiveRoot.appendingPathComponent("DocsArchive").path

        let rules = [
            // Rule 1 (higher priority): Images starting with "Screenshot" -> Screenshots folder
            ArchiveRule(
                name: "Screenshots",
                fileCategories: [.images],
                fileNameMatchMode: .glob,
                fileNamePattern: "screenshot*",
                sourceFolderPath: downloadsDir.path,
                destinationFolderPath: screenshotsDest
            ),
            // Rule 2: Other images -> Pictures
            ArchiveRule(
                name: "Pictures",
                fileCategories: [.images],
                destinationFolderPath: picturesDest
            ),
            // Rule 3: Videos -> Movies
            ArchiveRule(
                name: "Movies",
                fileCategories: [.videos],
                destinationFolderPath: moviesDest
            ),
            // Rule 4: Documents specifically from Documents folder
            ArchiveRule(
                name: "Documents From Documents",
                fileCategories: [.documents],
                sourceFolderPath: documentsDir.path,
                destinationFolderPath: docsDest
            )
        ]

        // Job WITHOUT fallback (DEC-008: unmatched stays untouched)
        let jobNoFallback = ArchiveJob(
            name: "Classified Archive",
            sourceFolders: [downloadsDir.path, documentsDir.path],
            rules: rules,
            fallbackDestinationPath: nil
        )

        let executor = ArchiveExecutor()
        let output = await executor.execute(job: jobNoFallback, trigger: .onDemand, mountedVolumePaths: ["/"])

        XCTAssertEqual(output.report.status, .completed)
        XCTAssertEqual(output.report.copiedCount, 4)
        XCTAssertEqual(output.report.unmatchedCount, 1)
        XCTAssertEqual(output.verifiedRecords.count, 4)

        // Verify classified destinations
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: (screenshotsDest as NSString).appendingPathComponent("Screenshot-2026.png")))
        XCTAssertTrue(fm.fileExists(atPath: (picturesDest as NSString).appendingPathComponent("vacation.jpg")))
        XCTAssertTrue(fm.fileExists(atPath: (moviesDest as NSString).appendingPathComponent("clip.mp4")))
        XCTAssertTrue(fm.fileExists(atPath: (docsDest as NSString).appendingPathComponent("tax.pdf")))

        // DEC-003 / REQ-005 AC 5: ALL originals MUST remain intact!
        XCTAssertTrue(fm.fileExists(atPath: pic.path))
        XCTAssertTrue(fm.fileExists(atPath: otherPic.path))
        XCTAssertTrue(fm.fileExists(atPath: movie.path))
        XCTAssertTrue(fm.fileExists(atPath: docFromDocs.path))
        XCTAssertTrue(fm.fileExists(atPath: unmatched.path))

        // Job WITH fallback destination (DEC-008): unmatched file routes to fallback.
        let fallbackDest = archiveRoot.appendingPathComponent("Unsorted").path
        var jobWithFallback = jobNoFallback
        jobWithFallback.fallbackDestinationPath = fallbackDest
        let output2 = await executor.execute(job: jobWithFallback, trigger: .onDemand, mountedVolumePaths: ["/"])
        XCTAssertEqual(output2.report.copiedCount, 1) // mystery.bin copied to fallback
        XCTAssertEqual(output2.report.duplicateCount, 4) // previously archived 4 files detected via SHA-256!
        XCTAssertTrue(fm.fileExists(atPath: (fallbackDest as NSString).appendingPathComponent("mystery.bin")))
    }

    func testSHA256CollisionSkipsExactDuplicateAndRenamesDifferentContentWithoutOverwriting() async throws {
        let fm = FileManager.default
        let destPictures = archiveRoot.appendingPathComponent("Pictures")
        try fm.createDirectory(at: destPictures, withIntermediateDirectories: true)

        // Pre-existing file in archive
        let existingArchiveFile = destPictures.appendingPathComponent("photo.jpg")
        try Data("original-archived-content".utf8).write(to: existingArchiveFile)

        // 1. Source with IDENTICAL content -> should skip as duplicate & record VerifiedArchiveRecord
        let srcFile = downloadsDir.appendingPathComponent("photo.jpg")
        try Data("original-archived-content".utf8).write(to: srcFile)

        let job = ArchiveJob(
            name: "Pictures Job",
            sourceFolders: [downloadsDir.path],
            rules: [ArchiveRule(name: "Pictures", fileCategories: [.images], destinationFolderPath: destPictures.path)]
        )

        let executor = ArchiveExecutor()
        let run1 = await executor.execute(job: job, trigger: .onDemand, mountedVolumePaths: ["/"])
        XCTAssertEqual(run1.report.duplicateCount, 1)
        XCTAssertEqual(run1.report.copiedCount, 0)
        XCTAssertEqual(run1.verifiedRecords.count, 1)

        // 2. Now replace source with DIFFERENT content -> must NOT overwrite existingArchiveFile; saves as "photo (2).jpg"!
        try Data("brand-new-photo-content".utf8).write(to: srcFile)
        let run2 = await executor.execute(job: job, trigger: .onDemand, mountedVolumePaths: ["/"])
        XCTAssertEqual(run2.report.renamedCount, 1)
        XCTAssertEqual(run2.verifiedRecords.count, 1)

        let renamedURL = destPictures.appendingPathComponent("photo (2).jpg")
        XCTAssertTrue(fm.fileExists(atPath: renamedURL.path))
        XCTAssertEqual(try Data(contentsOf: existingArchiveFile), Data("original-archived-content".utf8))
        XCTAssertEqual(try Data(contentsOf: renamedURL), Data("brand-new-photo-content".utf8))
        XCTAssertEqual(run2.verifiedRecords.first?.destinationPath, renamedURL.standardizedFileURL.path)

        // 3. Re-running with same updated source should recognize "photo (2).jpg" as exact SHA-256 duplicate!
        let run3 = await executor.execute(job: job, trigger: .onDemand, mountedVolumePaths: ["/"])
        XCTAssertEqual(run3.report.duplicateCount, 1)
        XCTAssertEqual(run3.report.renamedCount, 0)
    }

    func testDeferredWhenDestinationVolumeUnavailable() async throws {
        let srcFile = downloadsDir.appendingPathComponent("installer.dmg")
        try Data("installer-bytes".utf8).write(to: srcFile)

        let job = ArchiveJob(
            name: "External Archive",
            sourceFolders: [downloadsDir.path],
            rules: [ArchiveRule(name: "Installers", fileCategories: [.installers], destinationFolderPath: "/Volumes/OfflineDrive/Installers")]
        )

        let executor = ArchiveExecutor()
        let output = await executor.execute(job: job, trigger: .scheduled, mountedVolumePaths: ["/"])
        XCTAssertEqual(output.report.status, .deferredDestinationUnavailable)
        XCTAssertEqual(output.report.unavailableDestinations, ["/Volumes/OfflineDrive/Installers"])
        XCTAssertTrue(output.verifiedRecords.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcFile.path))
    }

    func testFallbackAndRulesPreserveFolderStructureByDefaultAndSupportFlatMode() async throws {
        let fm = FileManager.default
        let workDir = documentsDir.appendingPathComponent("Work/2026")
        let personalDir = documentsDir.appendingPathComponent("Personal/Recipes")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: personalDir, withIntermediateDirectories: true)

        let taxFile = workDir.appendingPathComponent("tax.pdf")
        let recipeFile = personalDir.appendingPathComponent("soup.txt")
        let topFile = documentsDir.appendingPathComponent("notes.md")
        try Data("tax-2026".utf8).write(to: taxFile)
        try Data("soup-recipe".utf8).write(to: recipeFile)
        try Data("root-notes".utf8).write(to: topFile)

        // 1. No rules + fallback destination -> preserves relative folder hierarchy by default (DEC-014).
        let preservedDest = archiveRoot.appendingPathComponent("DocumentsPreserved")
        let preservedJob = ArchiveJob(
            name: "Documents Full Tree",
            sourceFolders: [documentsDir.path],
            rules: [],
            fallbackDestinationPath: preservedDest.path
        )
        XCTAssertTrue(preservedJob.preserveFolderStructure)

        let executor = ArchiveExecutor()
        let preservedOut = await executor.execute(job: preservedJob, trigger: .onDemand, mountedVolumePaths: ["/"])
        XCTAssertEqual(preservedOut.report.status, .completed)
        XCTAssertEqual(preservedOut.report.copiedCount, 3)
        XCTAssertTrue(fm.fileExists(atPath: preservedDest.appendingPathComponent("Work/2026/tax.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath: preservedDest.appendingPathComponent("Personal/Recipes/soup.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: preservedDest.appendingPathComponent("notes.md").path))

        // Re-run recognizes existing nested copies as SHA-256 duplicates.
        let rerunOut = await executor.execute(job: preservedJob, trigger: .onDemand, mountedVolumePaths: ["/"])
        XCTAssertEqual(rerunOut.report.copiedCount, 0)
        XCTAssertEqual(rerunOut.report.duplicateCount, 3)

        // 2. Explicit flat mode (preserveFolderStructure = false) flattens files directly into target.
        let flatDest = archiveRoot.appendingPathComponent("DocumentsFlat")
        var flatJob = preservedJob
        flatJob.fallbackDestinationPath = flatDest.path
        flatJob.preserveFolderStructure = false
        let flatOut = await executor.execute(job: flatJob, trigger: .onDemand, mountedVolumePaths: ["/"])
        XCTAssertEqual(flatOut.report.copiedCount, 3)
        XCTAssertTrue(fm.fileExists(atPath: flatDest.appendingPathComponent("tax.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath: flatDest.appendingPathComponent("soup.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: flatDest.appendingPathComponent("notes.md").path))
        XCTAssertFalse(fm.fileExists(atPath: flatDest.appendingPathComponent("Work/2026/tax.pdf").path))

        // 3. Per-rule preserveRelativeSubpath defaults to true and can be set to false per rule.
        let rulePreservedDest = archiveRoot.appendingPathComponent("RulePreserved")
        let ruleFlatDest = archiveRoot.appendingPathComponent("RuleFlat")
        let ruleJob = ArchiveJob(
            name: "Rule Subfolder Modes",
            sourceFolders: [documentsDir.path],
            rules: [
                ArchiveRule(
                    name: "PDFs Keep Tree",
                    customExtensions: ["pdf"],
                    destinationFolderPath: rulePreservedDest.path
                ),
                ArchiveRule(
                    name: "TXT Flat",
                    customExtensions: ["txt"],
                    destinationFolderPath: ruleFlatDest.path,
                    preserveRelativeSubpath: false
                )
            ]
        )
        let ruleOut = await executor.execute(job: ruleJob, trigger: .onDemand, mountedVolumePaths: ["/"])
        XCTAssertEqual(ruleOut.report.copiedCount, 2)
        XCTAssertTrue(fm.fileExists(atPath: rulePreservedDest.appendingPathComponent("Work/2026/tax.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath: ruleFlatDest.appendingPathComponent("soup.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: ruleFlatDest.appendingPathComponent("Personal/Recipes/soup.txt").path))

        // 4. Backward compatibility: legacy JSON without `preserveFolderStructure` decodes to `true`.
        let legacyJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Legacy Documents Job",
          "sourceFolders": ["\(documentsDir.path)"],
          "rules": [],
          "fallbackDestinationPath": "\(preservedDest.path)",
          "includeSubdirectories": true,
          "skipHiddenFiles": true,
          "schedule": {
            "isEnabled": false,
            "frequency": "manual",
            "hour": 2,
            "minute": 0,
            "weekday": 1,
            "intervalMinutes": 60
          },
          "createdAt": 0
        }
        """
        let decoded = try JSONDecoder().decode(ArchiveJob.self, from: Data(legacyJSON.utf8))
        XCTAssertTrue(decoded.preserveFolderStructure)
    }
}
