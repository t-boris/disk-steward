import CryptoKit
import Foundation

/// Cached scan entry held in memory and persisted as an LZFSE-compressed snapshot,
/// tracking the exact set of dirty subdirectories that changed so updates rescan ONLY changed folders (DEC-012).
public struct CachedScanEntry: Sendable {
    public let rootPath: String
    public let result: ScanResult
    public var isDirty: Bool
    /// Exact directories inside `rootPath` where filesystem mutations occurred.
    public var dirtyDirectories: Set<String>
    public var invalidatedAt: Date?

    public init(
        rootPath: String,
        result: ScanResult,
        isDirty: Bool = false,
        dirtyDirectories: Set<String> = [],
        invalidatedAt: Date? = nil
    ) {
        self.rootPath = rootPath
        self.result = result
        self.isDirty = isDirty
        self.dirtyDirectories = dirtyDirectories
        self.invalidatedAt = invalidatedAt
    }

    /// Collapses `dirtyDirectories` so if both a parent and its child are dirty, only the parent is returned.
    /// If many sibling subfolders inside the same immediate child of `rootPath` are dirty (e.g. unzip/npm install),
    /// rolls them up to that common child folder so the dirty list stays compact and fast to rescan.
    public var minimalDirtyDirectories: [String] {
        Self.collapseMinimalDirectories(Array(dirtyDirectories), rootPath: rootPath)
    }

    /// True whenever there are specific subdirectories to incrementally rescan (never forces a root rescan).
    public var canIncrementalRefresh: Bool {
        let minimal = minimalDirtyDirectories
        guard !minimal.isEmpty else { return false }
        if minimal.count == 1 && minimal[0] == rootPath { return false }
        return true
    }

    public static func collapseMinimalDirectories(_ directories: [String], rootPath: String) -> [String] {
        let stdRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let uniqueSorted = Array(Set(directories.map { URL(fileURLWithPath: $0).standardizedFileURL.path }))
            .filter { dir in
                if stdRoot == "/" { return dir.hasPrefix("/") }
                return dir == stdRoot || dir.hasPrefix(stdRoot + "/")
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count < rhs.count }
                return lhs < rhs
            }

        var minimal: [String] = []
        for candidate in uniqueSorted {
            let coveredByExisting = minimal.contains { existing in
                if existing == "/" { return true }
                return candidate == existing || candidate.hasPrefix(existing + "/")
            }
            if !coveredByExisting {
                minimal.append(candidate)
            }
        }

        // If > 8 dirty directories accumulated (e.g. a batch operation across nested subfolders),
        // roll up branches that share a common parent below rootPath so incremental refresh stays tiny.
        if minimal.count > 8 {
            var groupedByTopChild: [String: [String]] = [:]
            for dir in minimal {
                let bucket = firstSubdirectory(of: dir, under: stdRoot) ?? dir
                groupedByTopChild[bucket, default: []].append(dir)
            }
            var rolledUp: [String] = []
            for (bucket, members) in groupedByTopChild {
                if members.count >= 4 && bucket != stdRoot {
                    rolledUp.append(bucket)
                } else {
                    rolledUp.append(contentsOf: members)
                }
            }
            minimal = Array(Set(rolledUp))
        }

        return minimal.sorted()
    }

    private static func firstSubdirectory(of path: String, under root: String) -> String? {
        if path == root { return root }
        let rel: String
        if root == "/" {
            rel = String(path.dropFirst())
        } else if path.hasPrefix(root + "/") {
            rel = String(path.dropFirst(root.count + 1))
        } else {
            return nil
        }
        guard let firstComp = rel.split(separator: "/").first else { return nil }
        return root == "/" ? "/\(firstComp)" : "\(root)/\(firstComp)"
    }
}

/// Manages in-memory + LZFSE-compressed on-disk storage scan caches with incremental dirty-folder
/// tracking and O(depth) subtree splicing (DEC-012).
public final class ScanCacheManager: @unchecked Sendable {
    private let lock = NSLock()
    private var entriesByRoot: [String: CachedScanEntry] = [:]
    public let cacheDirectoryURL: URL
    public let maxDiskCacheAgeSeconds: TimeInterval

    public init(
        cacheDirectoryURL: URL? = nil,
        maxDiskCacheAgeSeconds: TimeInterval = 24 * 3600
    ) {
        if let cacheDirectoryURL {
            self.cacheDirectoryURL = cacheDirectoryURL
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
            self.cacheDirectoryURL = caches.appendingPathComponent("DiskSteward/scans", isDirectory: true)
        }
        self.maxDiskCacheAgeSeconds = maxDiskCacheAgeSeconds
    }

    /// Stores a completed scan in memory and asynchronously writes a compressed LZFSE snapshot to disk.
    public func store(_ result: ScanResult, persistToDisk: Bool = true) {
        let rootPath = URL(fileURLWithPath: result.root.path).standardizedFileURL.path
        let entry = CachedScanEntry(rootPath: rootPath, result: result, isDirty: false, dirtyDirectories: [])

        lock.lock()
        entriesByRoot[rootPath] = entry
        lock.unlock()

        if persistToDisk && !result.wasCancelled {
            persistEntryToDisk(result: result, rootPath: rootPath)
        }
    }

    /// Looks up a cached scan for `path`:
    /// 1. Exact in-memory match (including dirty status & dirtyDirectories for incremental refresh).
    /// 2. Subtree slice from a cached ancestor (e.g. querying ~/Downloads when ~ or / is already cached!).
    /// 3. Compressed on-disk snapshot if present and within `maxDiskCacheAgeSeconds`.
    public func lookup(path: String, loadFromDiskIfNeeded: Bool = true) -> CachedScanEntry? {
        let stdPath = URL(fileURLWithPath: path).standardizedFileURL.path

        lock.lock()
        if let exact = entriesByRoot[stdPath] {
            lock.unlock()
            return exact
        }

        // Check if any cached ancestor already contains this exact folder subtree.
        let ancestorCandidates = entriesByRoot.values
            .filter { entry in
                if entry.rootPath == "/" { return stdPath.hasPrefix("/") && !stdPath.hasPrefix("/Volumes/") }
                return stdPath.hasPrefix(entry.rootPath + "/")
            }
            .sorted { $0.rootPath.count > $1.rootPath.count }

        for ancestor in ancestorCandidates {
            if let subNode = ancestor.result.root.findNode(at: stdPath), subNode.isDirectory {
                let subDirtyDirs = Set(
                    ancestor.dirtyDirectories.filter { dir in
                        dir == stdPath || dir.hasPrefix(stdPath + "/") || stdPath.hasPrefix(dir + "/")
                    }
                )
                let subResult = ScanResult(
                    root: subNode,
                    scannedAt: ancestor.result.scannedAt,
                    duration: 0,
                    totalFilesScanned: subNode.fileCount,
                    totalDirectoriesScanned: 1,
                    wasCancelled: ancestor.result.wasCancelled,
                    issues: ancestor.result.issues.filter { $0.path == stdPath || $0.path.hasPrefix(stdPath + "/") }
                )
                let derived = CachedScanEntry(
                    rootPath: stdPath,
                    result: subResult,
                    isDirty: !subDirtyDirs.isEmpty,
                    dirtyDirectories: subDirtyDirs,
                    invalidatedAt: subDirtyDirs.isEmpty ? nil : ancestor.invalidatedAt
                )
                lock.unlock()
                return derived
            }
        }
        lock.unlock()

        guard loadFromDiskIfNeeded else { return nil }
        return loadFromDisk(rootPath: stdPath)
    }

    /// Records the exact dirty subdirectories affected by `changedPaths` on matching cached roots
    /// so incremental refresh rescans ONLY those folders instead of the whole disk (DEC-012).
    @discardableResult
    public func invalidate(changedPaths: [String], now: Date = Date()) -> [String] {
        guard !changedPaths.isEmpty else { return [] }
        let fm = FileManager.default

        // Resolve each changed path to the nearest existing directory (so deleting a file marks its folder dirty,
        // and deleting a subfolder marks its parent folder dirty).
        let resolvedDirs: [String] = changedPaths.map { raw in
            Self.resolveTargetDirectory(forChangedPath: raw, fileManager: fm)
        }

        var affectedRoots: [String] = []

        lock.lock()
        for (rootPath, var entry) in entriesByRoot {
            var matchedDirs: [String] = []
            for dir in resolvedDirs {
                if rootPath == "/" {
                    if !dir.hasPrefix("/Volumes/") && dir != "/" {
                        matchedDirs.append(dir)
                    }
                } else if dir == rootPath || dir.hasPrefix(rootPath + "/") {
                    matchedDirs.append(dir)
                } else if rootPath.hasPrefix(dir + "/") {
                    // Ancestor of rootPath itself changed/deleted
                    matchedDirs.append(rootPath)
                }
            }

            if !matchedDirs.isEmpty {
                entry.isDirty = true
                entry.invalidatedAt = now
                for d in matchedDirs {
                    entry.dirtyDirectories.insert(d)
                }
                // Collapse nested dirty paths to keep set minimal.
                let collapsed = entry.minimalDirtyDirectories
                entry.dirtyDirectories = Set(collapsed)
                entriesByRoot[rootPath] = entry
                affectedRoots.append(rootPath)
            }
        }
        lock.unlock()

        return affectedRoots
    }

    /// Splices freshly rescanned subtrees back into the cached root tree for `rootPath` (and any cached
    /// ancestor trees containing those subtrees), preserving all untouched sibling folders, clearing dirty flags,
    /// and updating LZFSE disk snapshots (DEC-012).
    public func applyIncrementalUpdate(
        rootPath: String,
        updatedSubtrees: [(path: String, node: StorageNode?, addedIssues: [ScanIssue])],
        duration: TimeInterval,
        persistToDisk: Bool = true
    ) -> ScanResult? {
        let stdRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        var toPersist: [(rootPath: String, result: ScanResult)] = []
        var returnResult: ScanResult?

        lock.lock()
        // Patch every cached entry that contains stdRoot (exact match or ancestor).
        let matchingRoots = entriesByRoot.keys.filter { key in
            key == stdRoot || (key == "/" ? stdRoot.hasPrefix("/") && !stdRoot.hasPrefix("/Volumes/") : stdRoot.hasPrefix(key + "/"))
        }

        for key in matchingRoots {
            guard let existing = entriesByRoot[key] else { continue }
            var patchedRoot = existing.result.root
            var updatedIssues = existing.result.issues
            var cleanedDirtyDirs = existing.dirtyDirectories

            for update in updatedSubtrees {
                let stdSub = URL(fileURLWithPath: update.path).standardizedFileURL.path
                patchedRoot = patchedRoot.replacingSubtree(at: stdSub, with: update.node)

                updatedIssues.removeAll { issue in
                    issue.path == stdSub || issue.path.hasPrefix(stdSub + "/")
                }
                updatedIssues.append(contentsOf: update.addedIssues)

                cleanedDirtyDirs = cleanedDirtyDirs.filter { dirtyDir in
                    !(dirtyDir == stdSub || dirtyDir.hasPrefix(stdSub + "/"))
                }
            }

            let newResult = ScanResult(
                root: patchedRoot,
                scannedAt: Date(),
                duration: duration,
                totalFilesScanned: patchedRoot.fileCount,
                totalDirectoriesScanned: existing.result.totalDirectoriesScanned,
                wasCancelled: existing.result.wasCancelled,
                issues: updatedIssues
            )

            entriesByRoot[key] = CachedScanEntry(
                rootPath: key,
                result: newResult,
                isDirty: !cleanedDirtyDirs.isEmpty,
                dirtyDirectories: cleanedDirtyDirs,
                invalidatedAt: cleanedDirtyDirs.isEmpty ? nil : existing.invalidatedAt
            )

            if persistToDisk && !newResult.wasCancelled {
                toPersist.append((key, newResult))
            }

            if key == stdRoot {
                returnResult = newResult
            } else if returnResult == nil, let sliced = patchedRoot.findNode(at: stdRoot) {
                returnResult = ScanResult(
                    root: sliced,
                    scannedAt: newResult.scannedAt,
                    duration: duration,
                    totalFilesScanned: sliced.fileCount,
                    totalDirectoriesScanned: 1,
                    wasCancelled: newResult.wasCancelled,
                    issues: updatedIssues.filter { $0.path == stdRoot || $0.path.hasPrefix(stdRoot + "/") }
                )
            }
        }
        lock.unlock()

        for item in toPersist {
            persistEntryToDisk(result: item.result, rootPath: item.rootPath)
        }
        return returnResult
    }

    /// Resolves any filesystem change path (existing file, existing directory, or deleted path) to the
    /// nearest existing directory that should be incrementally rescanned.
    public static func resolveTargetDirectory(forChangedPath rawPath: String, fileManager fm: FileManager = .default) -> String {
        var current = URL(fileURLWithPath: rawPath).standardizedFileURL
        var isDir: ObjCBool = false

        if fm.fileExists(atPath: current.path, isDirectory: &isDir) {
            return isDir.boolValue ? current.path : current.deletingLastPathComponent().standardizedFileURL.path
        }

        // File or folder was deleted: walk up until finding the nearest existing parent directory.
        while current.path != "/" {
            current = current.deletingLastPathComponent().standardizedFileURL
            if fm.fileExists(atPath: current.path, isDirectory: &isDir), isDir.boolValue {
                return current.path
            }
        }
        return "/"
    }

    /// Removes a specific cached entry from both memory and disk.
    public func remove(rootPath: String) {
        let stdPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        lock.lock()
        entriesByRoot.removeValue(forKey: stdPath)
        lock.unlock()
        try? FileManager.default.removeItem(at: diskFileURL(forRootPath: stdPath))
    }

    /// Clears all in-memory and on-disk scan caches.
    public func clearAll() {
        lock.lock()
        entriesByRoot.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: cacheDirectoryURL)
    }

    /// Returns all currently cached root paths (used to configure FileSystemWatcher).
    public var cachedRootPaths: [String] {
        lock.lock()
        let keys = Array(entriesByRoot.keys).sorted()
        lock.unlock()
        return keys
    }

    private func persistEntryToDisk(result: ScanResult, rootPath: String) {
        let fileURL = diskFileURL(forRootPath: rootPath)
        let dirURL = cacheDirectoryURL
        DispatchQueue.global(qos: .background).async {
            autoreleasepool {
                do {
                    try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .secondsSince1970
                    let raw = try encoder.encode(result)
                    let compressed = try (raw as NSData).compressed(using: .lzfse) as Data
                    try compressed.write(to: fileURL, options: [.atomic])
                } catch {
                    // Best-effort disk cache.
                }
            }
        }
    }

    private func loadFromDisk(rootPath: String) -> CachedScanEntry? {
        let fileURL = diskFileURL(forRootPath: rootPath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return nil }

        if let mod = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate),
           Date().timeIntervalSince(mod) > maxDiskCacheAgeSeconds {
            try? fm.removeItem(at: fileURL)
            return nil
        }

        do {
            let compressed = try Data(contentsOf: fileURL)
            let raw = try (compressed as NSData).decompressed(using: .lzfse) as Data
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let scanResult = try decoder.decode(ScanResult.self, from: raw)
            let entry = CachedScanEntry(rootPath: rootPath, result: scanResult, isDirty: false, dirtyDirectories: [])
            lock.lock()
            entriesByRoot[rootPath] = entry
            lock.unlock()
            return entry
        } catch {
            try? fm.removeItem(at: fileURL)
            return nil
        }
    }

    private func diskFileURL(forRootPath rootPath: String) -> URL {
        let digest = SHA256.hash(data: Data(rootPath.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return cacheDirectoryURL.appendingPathComponent("\(hex).dsscan")
    }
}
