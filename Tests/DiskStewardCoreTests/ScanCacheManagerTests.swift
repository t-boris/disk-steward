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
}
