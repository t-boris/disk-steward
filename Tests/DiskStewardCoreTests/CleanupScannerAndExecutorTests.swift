import Foundation
import XCTest
@testable import DiskStewardCore

private final class RecordingFileDeleter: FileDeleter, @unchecked Sendable {
    var trashedURLs: [URL] = []
    var permanentlyDeletedURLs: [URL] = []
    var failingPaths: Set<String> = []

    func moveToTrash(url: URL) throws -> URL? {
        if failingPaths.contains(url.path) {
            throw NSError(domain: "TestError", code: 13, userInfo: [NSLocalizedDescriptionKey: "Simulated permission denied"])
        }
        trashedURLs.append(url)
        try FileManager.default.removeItem(at: url)
        return URL(fileURLWithPath: "/Users/test/.Trash/\(url.lastPathComponent)")
    }

    func deletePermanently(url: URL) throws {
        if failingPaths.contains(url.path) {
            throw NSError(domain: "TestError", code: 13, userInfo: [NSLocalizedDescriptionKey: "Simulated delete failure"])
        }
        permanentlyDeletedURLs.append(url)
        try FileManager.default.removeItem(at: url)
    }
}

private struct MockDockerRunner: CommandRunner {
    let available: Bool
    func findExecutable(named name: String) -> String? { available ? "/usr/local/bin/docker" : nil }
    func run(executablePath: String, arguments: [String]) async throws -> CommandOutput {
        guard available else { return CommandOutput(exitCode: 1, stdout: "", stderr: "not found") }
        switch arguments.first {
        case "info":
            return CommandOutput(exitCode: 0, stdout: "29.9.2", stderr: "")
        case "ps":
            return CommandOutput(
                exitCode: 0,
                stdout: #"{"ID":"abc123456789","Names":"old-api","Image":"node:18","State":"exited","Status":"Exited (0) 3 weeks ago","Size":"15MB"}"#,
                stderr: ""
            )
        case "images":
            return CommandOutput(
                exitCode: 0,
                stdout: """
                {"ID":"sha256:usedimage111","Repository":"node","Tag":"18","Size":"900MB"}
                {"ID":"sha256:unusedimg222","Repository":"ubuntu","Tag":"22.04","Size":"80MB"}
                """,
                stderr: ""
            )
        case "volume":
            if arguments.contains("ls") {
                return CommandOutput(exitCode: 0, stdout: #"{"Name":"orphan_vol"}"#, stderr: "")
            }
            return CommandOutput(exitCode: 0, stdout: "orphan_vol", stderr: "")
        case "system":
            return CommandOutput(exitCode: 0, stdout: #"{"Type":"Build Cache","Size":"2.5GB","Reclaimable":"1.5GB (60%)"}"#, stderr: "")
        case "rm", "rmi", "builder":
            return CommandOutput(exitCode: 0, stdout: "removed", stderr: "")
        default:
            return CommandOutput(exitCode: 0, stdout: "", stderr: "")
        }
    }
}

final class CleanupScannerAndExecutorTests: XCTestCase {
    private var fakeHome: URL!

    override func setUpWithError() throws {
        fakeHome = FileManager.default.temporaryDirectory.appendingPathComponent("DiskStewardCleanupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fakeHome {
            try? FileManager.default.removeItem(at: fakeHome)
        }
    }

    func testDiscoversAllFiveCategoriesReadOnlyAndDeclineLeavesAllDataIntact() async throws {
        let fm = FileManager.default
        let downloads = fakeHome.appendingPathComponent("Downloads")
        let archiveDir = fakeHome.appendingPathComponent("Archive")
        let projects = fakeHome.appendingPathComponent("Projects/demo-app/node_modules/pkg")
        let appCache = fakeHome.appendingPathComponent("Library/Caches/com.example.heavyapp")
        let appleCache = fakeHome.appendingPathComponent("Library/Caches/com.apple.bird")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: projects, withIntermediateDirectories: true)
        try fm.createDirectory(at: appCache, withIntermediateDirectories: true)
        try fm.createDirectory(at: appleCache, withIntermediateDirectories: true)

        // 1. Verified archived original
        let origFile = downloads.appendingPathComponent("archived-photo.png")
        let archiveCopy = archiveDir.appendingPathComponent("archived-photo.png")
        let photoData = Data(repeating: 0x11, count: 16_384)
        try photoData.write(to: origFile)
        try photoData.write(to: archiveCopy)
        let hash = try FileHasher.sha256(of: origFile)
        let modDate = (try origFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let verifiedRecord = VerifiedArchiveRecord(
            jobID: UUID(),
            sourcePath: origFile.standardizedFileURL.path,
            destinationPath: archiveCopy.standardizedFileURL.path,
            sha256: hash,
            fileSize: Int64(photoData.count),
            sourceModifiedDate: modDate
        )

        // 2. Large user file
        let bigFile = downloads.appendingPathComponent("big-dataset.zip")
        try Data(repeating: 0x22, count: 1_500_000).write(to: bigFile)

        // 3. Cache (> 5 MB) + protected Apple cache (> 5 MB, must be excluded!)
        try Data(repeating: 0x33, count: 6_000_000).write(to: appCache.appendingPathComponent("blob.cache"))
        try Data(repeating: 0x44, count: 6_000_000).write(to: appleCache.appendingPathComponent("cloud.cache"))

        // 4. node_modules
        try Data(repeating: 0x55, count: 50_000).write(to: projects.appendingPathComponent("index.js"))

        let config = AppConfiguration(
            cleanupLargeFileThresholdBytes: 1_000_000,
            cleanupUserFileRoots: [downloads.path],
            nodeModulesSearchRoots: [fakeHome.appendingPathComponent("Projects").path],
            includeCacheCleanup: true,
            includeDockerCleanup: true
        )

        let dockerInspector = DockerInspector(runner: MockDockerRunner(available: true))
        let scanner = CleanupScanner(dockerInspector: dockerInspector, homeDirectory: fakeHome.path)
        let proposal = await scanner.discoverProposals(configuration: config, verifiedArchives: [verifiedRecord])

        XCTAssertEqual(proposal.candidates(in: .archivedOriginals).count, 1)
        XCTAssertEqual(proposal.candidates(in: .userFiles).count, 1)
        XCTAssertEqual(proposal.candidates(in: .caches).count, 1, "Protected com.apple.* caches must be excluded")
        XCTAssertEqual(proposal.candidates(in: .nodeModules).count, 1)
        XCTAssertEqual(proposal.candidates(in: .dockerArtifacts).count, 4)

        // Discovery is strictly read-only.
        XCTAssertTrue(fm.fileExists(atPath: origFile.path))
        XCTAssertTrue(fm.fileExists(atPath: bigFile.path))

        // Declining (empty selection or mismatched proposal ID) leaves all data intact (REQ-006 AC 4).
        let deleter = RecordingFileDeleter()
        let executor = CleanupExecutor(fileDeleter: deleter, dockerInspector: dockerInspector, homeDirectory: fakeHome.path)
        let emptyResult = await executor.execute(
            proposal: proposal,
            confirmation: CleanupConfirmation(proposalID: proposal.id, confirmedCandidateIDs: [], deletionMode: .moveToTrash)
        )
        XCTAssertTrue(emptyResult.itemResults.isEmpty)
        XCTAssertTrue(deleter.trashedURLs.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: origFile.path))
        XCTAssertTrue(fm.fileExists(atPath: bigFile.path))

        // Confirm Trash mode (DEC-006 default) for archived original + big file + docker artifact.
        let selectedIDs = Set(
            proposal.candidates(in: .archivedOriginals).map(\.id)
                + proposal.candidates(in: .userFiles).map(\.id)
                + [proposal.candidates(in: .dockerArtifacts).first!.id]
        )
        let execResult = await executor.execute(
            proposal: proposal,
            confirmation: CleanupConfirmation(proposalID: proposal.id, confirmedCandidateIDs: selectedIDs, deletionMode: .moveToTrash)
        )
        XCTAssertEqual(execResult.succeededCount, 3)
        XCTAssertEqual(deleter.trashedURLs.count, 2)
        XCTAssertTrue(deleter.permanentlyDeletedURLs.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: origFile.path))
        XCTAssertTrue(fm.fileExists(atPath: archiveCopy.path), "Archive copy must remain intact!")
    }

    func testRevalidationProtectsModifiedFileAndCorruptedArchiveCopyAndReportsPartialFailure() async throws {
        let fm = FileManager.default
        let downloads = fakeHome.appendingPathComponent("Downloads")
        let archiveDir = fakeHome.appendingPathComponent("Archive")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        let fileA = downloads.appendingPathComponent("changed.bin")
        let fileB = downloads.appendingPathComponent("archived.bin")
        let archiveB = archiveDir.appendingPathComponent("archived.bin")
        let fileC = downloads.appendingPathComponent("will-fail.bin")
        let fileD = downloads.appendingPathComponent("will-succeed.bin")

        try Data(repeating: 0x01, count: 1_200_000).write(to: fileA)
        try Data("safe-archive".utf8).write(to: fileB)
        try Data("safe-archive".utf8).write(to: archiveB)
        try Data(repeating: 0x02, count: 1_200_000).write(to: fileC)
        try Data(repeating: 0x03, count: 1_200_000).write(to: fileD)

        let hashB = try FileHasher.sha256(of: fileB)
        let modB = (try fileB.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let recordB = VerifiedArchiveRecord(
            jobID: UUID(),
            sourcePath: fileB.standardizedFileURL.path,
            destinationPath: archiveB.standardizedFileURL.path,
            sha256: hashB,
            fileSize: 12,
            sourceModifiedDate: modB
        )

        let config = AppConfiguration(
            cleanupLargeFileThresholdBytes: 1_000_000,
            cleanupUserFileRoots: [downloads.path],
            nodeModulesSearchRoots: [],
            includeCacheCleanup: false,
            includeDockerCleanup: false
        )

        let scanner = CleanupScanner(dockerInspector: DockerInspector(runner: MockDockerRunner(available: false)), homeDirectory: fakeHome.path)
        let proposal = await scanner.discoverProposals(configuration: config, verifiedArchives: [recordB])
        XCTAssertEqual(proposal.candidates.count, 4)

        // Mutate fileA AFTER proposal was shown -> revalidation must refuse deletion!
        try Data(repeating: 0x99, count: 1_300_000).write(to: fileA)
        // Corrupt archive copy of fileB AFTER proposal was shown -> revalidation must preserve original fileB!
        try Data("corrupted!!!".utf8).write(to: archiveB)

        let deleter = RecordingFileDeleter()
        deleter.failingPaths.insert(fileC.standardizedFileURL.path)

        let executor = CleanupExecutor(fileDeleter: deleter, homeDirectory: fakeHome.path)
        let result = await executor.execute(
            proposal: proposal,
            confirmation: CleanupConfirmation(
                proposalID: proposal.id,
                confirmedCandidateIDs: Set(proposal.candidates.map(\.id)),
                deletionMode: .permanentDelete
            )
        )

        XCTAssertEqual(result.succeededCount, 1) // fileD permanently deleted
        XCTAssertEqual(result.skippedCount, 2)   // fileA (modified) & fileB (archive corrupted)
        XCTAssertEqual(result.failedCount, 1)    // fileC (simulated error)
        XCTAssertTrue(fm.fileExists(atPath: fileA.path))
        XCTAssertTrue(fm.fileExists(atPath: fileB.path))
        XCTAssertTrue(fm.fileExists(atPath: fileC.path))
        XCTAssertFalse(fm.fileExists(atPath: fileD.path))
        XCTAssertEqual(deleter.permanentlyDeletedURLs.count, 1)
    }
}
