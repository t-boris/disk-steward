import CryptoKit
import Foundation

/// Cached scan entry held in memory and optionally persisted as an LZFSE-compressed snapshot (DEC-012).
public struct CachedScanEntry: Sendable {
    public let rootPath: String
    public let result: ScanResult
    public var isDirty: Bool
    public var dirtySamplePaths: [String]
    public var invalidatedAt: Date?

    public init(
        rootPath: String,
        result: ScanResult,
        isDirty: Bool = false,
        dirtySamplePaths: [String] = [],
        invalidatedAt: Date? = nil
    ) {
        self.rootPath = rootPath
        self.result = result
        self.isDirty = isDirty
        self.dirtySamplePaths = dirtySamplePaths
        self.invalidatedAt = invalidatedAt
    }
}

/// Manages in-memory + LZFSE-compressed on-disk storage scan caches with automatic invalidation
/// on filesystem changes (FSEvents) or app-initiated cleanup/archiving operations (DEC-012).
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
        let entry = CachedScanEntry(rootPath: rootPath, result: result, isDirty: false)

        lock.lock()
        entriesByRoot[rootPath] = entry
        lock.unlock()

        if persistToDisk && !result.wasCancelled {
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
                        // Best-effort disk cache; ignore write errors silently.
                    }
                }
            }
        }
    }

    /// Looks up a cached scan for `path`:
    /// 1. Exact in-memory match.
    /// 2. Subtree slice from a clean cached ancestor (e.g. querying ~/Downloads when ~ or / is already cached!).
    /// 3. Compressed on-disk snapshot if present and within `maxDiskCacheAgeSeconds`.
    public func lookup(path: String, loadFromDiskIfNeeded: Bool = true) -> CachedScanEntry? {
        let stdPath = URL(fileURLWithPath: path).standardizedFileURL.path

        lock.lock()
        if let exact = entriesByRoot[stdPath] {
            lock.unlock()
            return exact
        }

        // Check if any clean cached ancestor already contains this exact folder subtree!
        let ancestorCandidates = entriesByRoot.values
            .filter { entry in
                guard !entry.isDirty else { return false }
                if entry.rootPath == "/" { return stdPath.hasPrefix("/") }
                return stdPath.hasPrefix(entry.rootPath + "/")
            }
            .sorted { $0.rootPath.count > $1.rootPath.count }

        for ancestor in ancestorCandidates {
            if let subNode = ancestor.result.root.findNode(at: stdPath), subNode.isDirectory {
                let subResult = ScanResult(
                    root: subNode,
                    scannedAt: ancestor.result.scannedAt,
                    duration: 0,
                    totalFilesScanned: subNode.fileCount,
                    totalDirectoriesScanned: 1,
                    wasCancelled: ancestor.result.wasCancelled,
                    issues: ancestor.result.issues.filter { $0.path == stdPath || $0.path.hasPrefix(stdPath + "/") }
                )
                let derived = CachedScanEntry(rootPath: stdPath, result: subResult, isDirty: false)
                lock.unlock()
                return derived
            }
        }
        lock.unlock()

        guard loadFromDiskIfNeeded else { return nil }
        return loadFromDisk(rootPath: stdPath)
    }

    /// Marks any cached root affected by `changedPaths` as dirty and deletes its stale disk snapshot.
    /// Returns the list of root paths that transitioned to dirty.
    @discardableResult
    public func invalidate(changedPaths: [String], now: Date = Date()) -> [String] {
        guard !changedPaths.isEmpty else { return [] }
        let normalizedChanges = changedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }

        var affectedRoots: [String] = []
        var diskFilesToRemove: [URL] = []

        lock.lock()
        for (rootPath, var entry) in entriesByRoot {
            let matching = normalizedChanges.filter { change in
                if rootPath == "/" {
                    // Ignore changes on other mounted external volumes under /Volumes/* when checking "/".
                    return !change.hasPrefix("/Volumes/")
                }
                return change == rootPath || change.hasPrefix(rootPath + "/") || rootPath.hasPrefix(change + "/")
            }
            if !matching.isEmpty {
                entry.isDirty = true
                entry.invalidatedAt = now
                entry.dirtySamplePaths = Array(Set(entry.dirtySamplePaths + matching).prefix(10))
                entriesByRoot[rootPath] = entry
                affectedRoots.append(rootPath)
                diskFilesToRemove.append(diskFileURL(forRootPath: rootPath))
            }
        }
        lock.unlock()

        for fileURL in diskFilesToRemove {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return affectedRoots
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
            let entry = CachedScanEntry(rootPath: rootPath, result: scanResult, isDirty: false)
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
