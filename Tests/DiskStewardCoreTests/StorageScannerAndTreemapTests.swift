import Foundation
import XCTest
@testable import DiskStewardCore

final class StorageScannerAndTreemapTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DiskStewardScanTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            // Ensure permissions are restored before cleanup.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
            if let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
                for case let url as URL in enumerator {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                }
            }
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testScannerCollectsSizesSkipsSymlinkLoopsAndReportsInaccessibleDirectories() async throws {
        let fm = FileManager.default
        let mediaDir = tempDir.appendingPathComponent("Media")
        let restrictedDir = tempDir.appendingPathComponent("Restricted")
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: restrictedDir, withIntermediateDirectories: true)

        let bigVideo = mediaDir.appendingPathComponent("movie.mp4")
        let smallDoc = tempDir.appendingPathComponent("notes.pdf")
        try Data(repeating: 0xAA, count: 64_000).write(to: bigVideo)
        try Data(repeating: 0xBB, count: 4_000).write(to: smallDoc)

        // Create a symlink loop back to tempDir — scanner must NOT loop infinitely.
        let loopLink = mediaDir.appendingPathComponent("loop-to-root")
        try fm.createSymbolicLink(at: loopLink, withDestinationURL: tempDir)

        // Make Restricted unreadable to verify incomplete-scan reporting (plan I-3).
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restrictedDir.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: restrictedDir.path)
        }

        let scanner = StorageScanner()
        let result = await scanner.scan(rootURL: tempDir)

        XCTAssertFalse(result.wasCancelled)
        XCTAssertFalse(result.isComplete, "Scan with unreadable directory must be marked incomplete")
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.root.hasInaccessibleDescendants)
        XCTAssertGreaterThanOrEqual(result.root.logicalSize, 68_000)

        // Largest child at root should be Media (contains 64 KB movie) ahead of notes.pdf.
        XCTAssertEqual(result.root.children.first?.name, "Media")
    }

    func testTreemapAreasAreStrictlyProportionalToSizes() {
        let now = Date()
        let nodes = [
            StorageNode(name: "A.mp4", path: "/A.mp4", isDirectory: false, allocatedSize: 600, modifiedDate: now, category: .videos),
            StorageNode(name: "B.dmg", path: "/B.dmg", isDirectory: false, allocatedSize: 300, modifiedDate: now, category: .installers),
            StorageNode(name: "C.png", path: "/C.png", isDirectory: false, allocatedSize: 100, modifiedDate: now, category: .images)
        ]

        let bounds = TreemapRect(x: 0, y: 0, width: 1000, height: 500)
        let tiles = TreemapLayout.compute(nodes: nodes, in: bounds)

        XCTAssertEqual(tiles.count, 3)
        let totalTileArea = tiles.reduce(0.0) { $0 + $1.rect.area }
        XCTAssertEqual(totalTileArea, bounds.area, accuracy: 0.01)

        let byName = Dictionary(uniqueKeysWithValues: tiles.map { ($0.node.name, $0) })
        XCTAssertEqual(byName["A.mp4"]!.rect.area / bounds.area, 0.6, accuracy: 0.0001)
        XCTAssertEqual(byName["B.dmg"]!.rect.area / bounds.area, 0.3, accuracy: 0.0001)
        XCTAssertEqual(byName["C.png"]!.rect.area / bounds.area, 0.1, accuracy: 0.0001)
    }

    func testStorageAnalyzerBreakdownsFiltersAndDateColorLegend() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recentDate = now.addingTimeInterval(-2 * 86_400)     // < 7 days
        let oldDate = now.addingTimeInterval(-400 * 86_400)      // > 1 year
        let midDate = now.addingTimeInterval(-90 * 86_400)       // 1-6 months

        let f1 = StorageNode(name: "recent.png", path: "/root/recent.png", isDirectory: false, allocatedSize: 500, modifiedDate: recentDate, category: .images)
        let f2 = StorageNode(name: "old-movie.mp4", path: "/root/sub/old-movie.mp4", isDirectory: false, allocatedSize: 2_000, modifiedDate: oldDate, category: .videos)
        let f3 = StorageNode(name: "mid.pdf", path: "/root/sub/mid.pdf", isDirectory: false, allocatedSize: 1_000, modifiedDate: midDate, category: .documents)
        let sub = StorageNode(name: "sub", path: "/root/sub", isDirectory: true, allocatedSize: 3_000, fileCount: 2, modifiedDate: midDate, category: .other, children: [f2, f3])
        let root = StorageNode(name: "root", path: "/root", isDirectory: true, allocatedSize: 3_500, fileCount: 3, modifiedDate: recentDate, category: .other, children: [sub, f1])

        // Size ranking
        let largest = StorageAnalyzer.largestItems(in: root, relativeTo: now)
        XCTAssertEqual(largest.map(\.name), ["old-movie.mp4", "mid.pdf", "recent.png"])

        // File type breakdown
        let catBreakdown = StorageAnalyzer.categoryBreakdown(in: root, relativeTo: now)
        XCTAssertEqual(catBreakdown.first?.category, .videos)
        XCTAssertEqual(catBreakdown.first?.totalBytes, 2_000)

        // Date breakdown & explained color legend (REQ-004 AC 3)
        let ageBreakdown = StorageAnalyzer.ageBreakdown(in: root, relativeTo: now)
        let overYear = ageBreakdown.first { $0.bucket == .over1Year }
        XCTAssertEqual(overYear?.totalBytes, 2_000)
        let legend = StorageAnalyzer.dateColorLegend
        XCTAssertEqual(legend.count, AgeBucket.allCases.count)
        XCTAssertTrue(legend.allSatisfy { !$0.explanation.isEmpty && !$0.label.isEmpty && !$0.hex.isEmpty })

        // Filter by file type + older than 1 year
        let filter = StorageFilter(includedCategories: [.videos], datePreset: .olderThan1Year)
        let filtered = StorageAnalyzer.filteredTree(root, filter: filter, relativeTo: now)
        XCTAssertNotNil(filtered)
        XCTAssertEqual(filtered?.allocatedSize, 2_000)
        XCTAssertEqual(filtered?.fileCount, 1)

        // Custom date range ("not older than" / "not newer than")
        let customFilter = StorageFilter(
            datePreset: .custom,
            notOlderThan: now.addingTimeInterval(-120 * 86_400),
            notNewerThan: now.addingTimeInterval(-10 * 86_400)
        )
        let customFiltered = StorageAnalyzer.filteredTree(root, filter: customFilter, relativeTo: now)
        XCTAssertEqual(customFiltered?.allocatedSize, 1_000)
        XCTAssertEqual(StorageAnalyzer.largestItems(in: root, filter: customFilter, relativeTo: now).map(\.name), ["mid.pdf"])
    }

    func testSkipsMacOSVirtualPortalsAndNestedVolumePaths() {
        // Scanning "/" must skip /.nofollow, /.resolve, /.vol, /System/Volumes, /Volumes, /dev
        XCTAssertTrue(StorageScanner.shouldSkipVirtualPath("/.nofollow", rootPath: "/"))
        XCTAssertTrue(StorageScanner.shouldSkipVirtualPath("/.resolve", rootPath: "/"))
        XCTAssertTrue(StorageScanner.shouldSkipVirtualPath("/.vol", rootPath: "/"))
        XCTAssertTrue(StorageScanner.shouldSkipVirtualPath("/System/Volumes", rootPath: "/"))
        XCTAssertTrue(StorageScanner.shouldSkipVirtualPath("/System/Volumes", rootPath: "/System"))
        XCTAssertTrue(StorageScanner.shouldSkipVirtualPath("/Volumes", rootPath: "/"))
        XCTAssertTrue(StorageScanner.shouldSkipVirtualPath("/dev", rootPath: "/"))

        // Scanning an external volume under /Volumes must NOT be blocked
        XCTAssertFalse(StorageScanner.shouldSkipVirtualPath("/Volumes/Storage0", rootPath: "/Volumes/Storage0"))
        XCTAssertFalse(StorageScanner.shouldSkipVirtualPath("/Volumes", rootPath: "/Volumes/Storage0"))
        XCTAssertFalse(StorageScanner.shouldSkipVirtualPath("/Users", rootPath: "/"))
    }

    func testNestedStructuralTreemapNestsChildrenInsideParentsWithContrastingAdjacentColors() {
        let now = Date()
        let f1 = StorageNode(name: "clip1.mp4", path: "/root/Videos/clip1.mp4", isDirectory: false, allocatedSize: 500, modifiedDate: now, category: .videos)
        let f2 = StorageNode(name: "clip2.mp4", path: "/root/Videos/clip2.mp4", isDirectory: false, allocatedSize: 300, modifiedDate: now, category: .videos)
        let videos = StorageNode(name: "Videos", path: "/root/Videos", isDirectory: true, allocatedSize: 800, fileCount: 2, modifiedDate: now, category: .other, children: [f1, f2])

        let c1 = StorageNode(name: "app.swift", path: "/root/Code/app.swift", isDirectory: false, allocatedSize: 250, modifiedDate: now, category: .code)
        let c2 = StorageNode(name: "bundle.zip", path: "/root/Code/bundle.zip", isDirectory: false, allocatedSize: 150, modifiedDate: now, category: .archives)
        let code = StorageNode(name: "Code", path: "/root/Code", isDirectory: true, allocatedSize: 400, fileCount: 2, modifiedDate: now, category: .other, children: [c1, c2])

        let root = StorageNode(name: "root", path: "/root", isDirectory: true, allocatedSize: 1200, fileCount: 4, modifiedDate: now, category: .other, children: [videos, code])

        let bounds = TreemapRect(x: 0, y: 0, width: 800, height: 600)
        let nested = TreemapLayout.computeNested(scope: root, in: bounds, maxDepth: 3)

        let depth0 = nested.filter { $0.depth == 0 }
        let depth1 = nested.filter { $0.depth == 1 }
        XCTAssertEqual(depth0.count, 2)
        XCTAssertEqual(depth1.count, 4, "Both top-level folders must recursively render their nested child files")

        // Adjacent top-level siblings must have contrasting colors (DEC-010).
        XCTAssertNotEqual(depth0[0].colorIndex, depth0[1].colorIndex)

        // Nested children must sit strictly inside their parent folder's rectangle and contrast with parent color.
        let videosTile = depth0.first { $0.node.name == "Videos" }!
        let videoChildren = depth1.filter { $0.node.path.hasPrefix("/root/Videos/") }
        XCTAssertEqual(videoChildren.count, 2)
        for child in videoChildren {
            XCTAssertNotEqual(child.colorIndex, videosTile.colorIndex)
            XCTAssertGreaterThanOrEqual(child.rect.x, videosTile.rect.x - 0.01)
            XCTAssertGreaterThanOrEqual(child.rect.y, videosTile.rect.y - 0.01)
            XCTAssertLessThanOrEqual(child.rect.maxX, videosTile.rect.maxX + 0.01)
            XCTAssertLessThanOrEqual(child.rect.maxY, videosTile.rect.maxY + 0.01)
        }
        XCTAssertNotEqual(videoChildren[0].colorIndex, videoChildren[1].colorIndex)

        // Single-level mode (maxDepth: 0) renders strictly immediate children with distinct contrasting colors (DEC-010).
        let singleLevel = TreemapLayout.computeNested(scope: root, in: bounds, maxDepth: 0)
        XCTAssertEqual(singleLevel.count, 2)
        XCTAssertTrue(singleLevel.allSatisfy { $0.depth == 0 && !$0.hasRenderedChildren })
        XCTAssertNotEqual(singleLevel[0].colorIndex, singleLevel[1].colorIndex)

        // Custom extension filter narrows scope cleanly.
        let zipFilter = StorageFilter(customExtensions: ["zip"])
        let filtered = StorageAnalyzer.filteredTree(root, filter: zipFilter, relativeTo: now)
        XCTAssertEqual(filtered?.fileCount, 1)
        XCTAssertEqual(filtered?.allocatedSize, 150)
    }
}
