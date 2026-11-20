import Foundation
import XCTest
@testable import DiskStewardCore

final class ScanCacheManagerTests: XCTestCase {
    private var cacheDir: URL!

    override func setUpWithError() throws {
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskStewardScanCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let cacheDir {
            try? FileManager.default.removeItem(at: cacheDir)
        }
    }

    func testCachesInMemoryReusesParentSubtreePersistsLZFSEAndInvalidatesOnFSChange() throws {
        let now = Date()
        let fileA = StorageNode(name: "movie.mp4", path: "/Users/test/Downloads/movie.mp4", isDirectory: false, allocatedSize: 500_000, modifiedDate: now, category: .videos)
        let downloads = StorageNode(name: "Downloads", path: "/Users/test/Downloads", isDirectory: true, allocatedSize: 500_000, fileCount: 1, modifiedDate: now, category: .other, children: [fileA])
        let fileB = StorageNode(name: "doc.pdf", path: "/Users/test/Documents/doc.pdf", isDirectory: false, allocatedSize: 100_000, modifiedDate: now, category: .documents)
        let documents = StorageNode(name: "Documents", path: "/Users/test/Documents", isDirectory: true, allocatedSize: 100_000, fileCount: 1, modifiedDate: now, category: .other, children: [fileB])
        let home = StorageNode(name: "test", path: "/Users/test", isDirectory: true, allocatedSize: 600_000, fileCount: 2, modifiedDate: now, category: .other, children: [downloads, documents])

        let scanResult = ScanResult(root: home, scannedAt: now, duration: 1.2, totalFilesScanned: 2, totalDirectoriesScanned: 3)

        let manager = ScanCacheManager(cacheDirectoryURL: cacheDir)
        manager.store(scanResult, persistToDisk: true)

        // 1. Exact in-memory lookup
        let exactHit = manager.lookup(path: "/Users/test", loadFromDiskIfNeeded: false)
        XCTAssertNotNil(exactHit)
        XCTAssertEqual(exactHit?.isDirty, false)
        XCTAssertEqual(exactHit?.result.root.allocatedSize, 600_000)

        // 2. Ancestor subtree reuse without rescanning!
        let subHit = manager.lookup(path: "/Users/test/Downloads", loadFromDiskIfNeeded: false)
        XCTAssertNotNil(subHit)
        XCTAssertEqual(subHit?.result.root.path, "/Users/test/Downloads")
        XCTAssertEqual(subHit?.result.root.allocatedSize, 500_000)

        // 3. Wait briefly for async LZFSE disk snapshot write and load in a fresh manager instance
        Thread.sleep(forTimeInterval: 0.25)
        let coldManager = ScanCacheManager(cacheDirectoryURL: cacheDir)
        let diskHit = coldManager.lookup(path: "/Users/test", loadFromDiskIfNeeded: true)
        XCTAssertNotNil(diskHit, "Fresh manager must load LZFSE-compressed scan snapshot from disk")
        XCTAssertEqual(diskHit?.result.root.allocatedSize, 600_000)
        XCTAssertEqual(diskHit?.result.root.children.count, 2)

        // 4. Filesystem change invalidates affected root and removes stale disk snapshot
        let affected = manager.invalidate(changedPaths: ["/Users/test/Downloads/new.zip"])
        XCTAssertEqual(affected, ["/Users/test"])
        let dirtyEntry = manager.lookup(path: "/Users/test", loadFromDiskIfNeeded: false)
        XCTAssertEqual(dirtyEntry?.isDirty, true)

        // Unrelated external volume change must NOT invalidate /Users/test
        let coldAffected = coldManager.invalidate(changedPaths: ["/Volumes/Storage1/foo.mp4"])
        XCTAssertTrue(coldAffected.isEmpty)

        // 5. ExplorerSnapshot single-pass builder returns exact totals, top files, and breakdowns
        let snap = StorageAnalyzer.buildSnapshot(for: home, filter: StorageFilter(), largestLimit: 10, relativeTo: now)
        XCTAssertEqual(snap.scopeAllocatedBytes, 600_000)
        XCTAssertEqual(snap.directChildren.map(\.name), ["Downloads", "Documents"])
        XCTAssertEqual(snap.largestItems.map(\.name), ["movie.mp4", "doc.pdf"])
        XCTAssertEqual(snap.categoryBreakdown.first?.category, .videos)
    }

    func testIncrementalSubtreeSpliceUpdatesOnlyChangedFolderAndPreservesUntouchedSiblings() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("DiskStewardSpliceTest-\(UUID().uuidString)")
        let folderA = tempRoot.appendingPathComponent("FolderA")
        let folderB = tempRoot.appendingPathComponent("FolderB")
        try fm.createDirectory(at: folderA, withIntermediateDirectories: true)
        try fm.createDirectory(at: folderB, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let fileA1 = folderA.appendingPathComponent("big.bin")
        let fileA2 = folderA.appendingPathComponent("keep.bin")
        let fileB1 = folderB.appendingPathComponent("untouched.bin")
        try Data(repeating: 0xAA, count: 65_536).write(to: fileA1)
        try Data(repeating: 0xBB, count: 8_192).write(to: fileA2)
        try Data(repeating: 0xCC, count: 32_768).write(to: fileB1)

        let scanner = StorageScanner()
        let initialScan = await scanner.scan(rootURL: tempRoot)
        let manager = ScanCacheManager(cacheDirectoryURL: cacheDir)
        manager.store(initialScan, persistToDisk: false)

        let originalFolderBRef = initialScan.root.findNode(at: folderB.standardizedFileURL.path)!

        // Delete big.bin inside FolderA (simulating cleaning a folder in Finder)
        try fm.removeItem(at: fileA1)
        let affectedRoots = manager.invalidate(changedPaths: [fileA1.path])
        XCTAssertEqual(affectedRoots, [tempRoot.standardizedFileURL.path])

        let dirtyEntry = manager.lookup(path: tempRoot.path, loadFromDiskIfNeeded: false)!
        XCTAssertTrue(dirtyEntry.isDirty)
        XCTAssertEqual(dirtyEntry.minimalDirtyDirectories, [folderA.standardizedFileURL.path])
        XCTAssertTrue(dirtyEntry.canIncrementalRefresh)

        // Incrementally rescan ONLY FolderA (NOT FolderB or tempRoot!)
        let subScan = await scanner.scan(rootURL: folderA)
        let patched = manager.applyIncrementalUpdate(
            rootPath: tempRoot.path,
            updatedSubtrees: [(path: folderA.path, node: subScan.root, addedIssues: subScan.issues)],
            duration: subScan.duration,
            persistToDisk: false
        )!

        // FolderA size dropped, total root size dropped, FolderB is now larger than FolderA (re-sorted!),
        // AND FolderB kept the EXACT SAME object reference (never rescanned or copied!).
        XCTAssertLessThan(patched.root.allocatedSize, initialScan.root.allocatedSize)
        XCTAssertEqual(patched.root.fileCount, 2)
        XCTAssertEqual(patched.root.children.first?.name, "FolderB")
        XCTAssertTrue(patched.root.children.first === originalFolderBRef, "Untouched sibling folder must keep exact cached reference")

        let cleanEntry = manager.lookup(path: tempRoot.path, loadFromDiskIfNeeded: false)!
        XCTAssertFalse(cleanEntry.isDirty)
        XCTAssertTrue(cleanEntry.minimalDirtyDirectories.isEmpty)
    }

    func testFileSystemWatcherFiltersNoisyAppCachesAndWALFilesAndRollsUpBurstDirtyFolders() {
        // High-frequency background runtime/cache/WAL files must be ignored so dirty count doesn't spam.
        XCTAssertTrue(FileSystemWatcher.shouldIgnorePath("/Users/boris/Library/Application Support/Google/Chrome/Default/History-wal"))
        XCTAssertTrue(FileSystemWatcher.shouldIgnorePath("/Users/boris/Library/Caches/com.google.Chrome/Cache_Data/f_001"))
        XCTAssertTrue(FileSystemWatcher.shouldIgnorePath("/Users/boris/.gemini/antigravity-cli/brain/transcript.jsonl"))
        XCTAssertTrue(FileSystemWatcher.shouldIgnorePath("/Users/boris/github.com/app/db.sqlite-shm"))
        XCTAssertTrue(FileSystemWatcher.shouldIgnorePath("/"))

        // Real user folder changes must NOT be ignored.
        XCTAssertFalse(FileSystemWatcher.shouldIgnorePath("/Users/boris/Downloads/OldVideos/clip.mp4"))
        XCTAssertFalse(FileSystemWatcher.shouldIgnorePath("/Users/boris/Documents/report.pdf"))
        XCTAssertFalse(FileSystemWatcher.shouldIgnorePath("/Volumes/Storage1/Archive/photo.jpg"))

        // Burst of 12 dirty subfolders inside Downloads rolls up cleanly into just Downloads.
        let burst = (1...12).map { "/Users/boris/Downloads/batch/dir\($0)" }
        let collapsed = CachedScanEntry.collapseMinimalDirectories(burst, rootPath: "/Users/boris")
        XCTAssertEqual(collapsed, ["/Users/boris/Downloads"])
    }
}
