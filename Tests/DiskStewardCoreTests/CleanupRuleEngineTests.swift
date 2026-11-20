import Foundation
import XCTest
@testable import DiskStewardCore

private final class RuleTestDeleter: FileDeleter, @unchecked Sendable {
    var trashedPaths: [String] = []
    var permanentlyDeletedPaths: [String] = []

    func moveToTrash(url: URL) throws -> URL? {
        trashedPaths.append(url.path)
        try FileManager.default.removeItem(at: url)
        return URL(fileURLWithPath: "/Users/test/.Trash/\(url.lastPathComponent)")
    }

    func deletePermanently(url: URL) throws {
        permanentlyDeletedPaths.append(url.path)
        try FileManager.default.removeItem(at: url)
    }
}

final class CleanupRuleEngineTests: XCTestCase {
    private var rootDir: URL!

    override func setUpWithError() throws {
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskStewardRuleCleanupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootDir {
            try? FileManager.default.removeItem(at: rootDir)
        }
    }

    func testFindsAndConfirmedDeletesCodeZipAndVideoFilesRecursivelyWhileProtectingGit() async throws {
        let fm = FileManager.default
        let nested = rootDir.appendingPathComponent("sub/deep")
        let gitDir = rootDir.appendingPathComponent(".git/objects")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)

        let swiftFile = rootDir.appendingPathComponent("main.swift")
        let pyFile = nested.appendingPathComponent("script.py")
        let zipFile = nested.appendingPathComponent("backup.zip")
        let videoFile = rootDir.appendingPathComponent("demo.mp4")
        let docFile = rootDir.appendingPathComponent("keep.pdf")
        let gitCodeFile = gitDir.appendingPathComponent("hook.py")

        try Data("print(1)".utf8).write(to: swiftFile)
        try Data("print(2)".utf8).write(to: pyFile)
        try Data(repeating: 0x50, count: 4096).write(to: zipFile)
        try Data(repeating: 0x60, count: 8192).write(to: videoFile)
        try Data("keep".utf8).write(to: docFile)
        try Data("git".utf8).write(to: gitCodeFile)

        let engine = CleanupRuleEngine()

        // 1. Delete all code files recursively (must skip .git!)
        let codeRule = CleanupRule(
            name: "All Code",
            folderPath: rootDir.path,
            includeSubdirectories: true,
            fileCategories: [.code]
        )
        let codeProposal = engine.buildProposal(for: codeRule)
        XCTAssertEqual(Set(codeProposal.candidates.map(\.title)), ["main.swift", "script.py"])

        // 2. Delete all .zip files specifically via custom extension
        let zipRule = CleanupRule(
            name: "All ZIPs",
            folderPath: rootDir.path,
            includeSubdirectories: true,
            customExtensions: ["zip"]
        )
        let zipProposal = engine.buildProposal(for: zipRule)
        XCTAssertEqual(zipProposal.candidates.map(\.title), ["backup.zip"])

        // 3. Delete all video files
        let videoRule = CleanupRule(
            name: "All Videos",
            folderPath: rootDir.path,
            includeSubdirectories: true,
            fileCategories: [.videos]
        )
        let videoProposal = engine.buildProposal(for: videoRule)
        XCTAssertEqual(videoProposal.candidates.map(\.title), ["demo.mp4"])

        // 4. Execute confirmed deletion on codeProposal -> moves code files to Trash, keeps zip/video/pdf/.git intact!
        let deleter = RuleTestDeleter()
        let executor = CleanupExecutor(fileDeleter: deleter, homeDirectory: rootDir.deletingLastPathComponent().path)
        let result = await executor.execute(
            proposal: codeProposal,
            confirmation: CleanupConfirmation(
                proposalID: codeProposal.id,
                confirmedCandidateIDs: Set(codeProposal.candidates.map(\.id)),
                deletionMode: .moveToTrash
            )
        )
        XCTAssertEqual(result.succeededCount, 2)
        XCTAssertFalse(fm.fileExists(atPath: swiftFile.path))
        XCTAssertFalse(fm.fileExists(atPath: pyFile.path))
        XCTAssertTrue(fm.fileExists(atPath: zipFile.path))
        XCTAssertTrue(fm.fileExists(atPath: videoFile.path))
        XCTAssertTrue(fm.fileExists(atPath: docFile.path))
        XCTAssertTrue(fm.fileExists(atPath: gitCodeFile.path))
    }

    func testRefusesProtectedSystemRootAndEmptyCriteriaRule() {
        let engine = CleanupRuleEngine()

        let rootRule = CleanupRule(name: "Bad Root", folderPath: "/", fileCategories: [.code])
        let rootRes = engine.evaluate(rule: rootRule)
        XCTAssertTrue(rootRes.candidates.isEmpty)
        XCTAssertFalse(rootRes.notes.isEmpty)

        let emptyRule = CleanupRule(name: "Too Broad", folderPath: rootDir.path)
        let emptyRes = engine.evaluate(rule: emptyRule)
        XCTAssertTrue(emptyRes.candidates.isEmpty)
        XCTAssertFalse(emptyRes.notes.isEmpty)
    }
}
