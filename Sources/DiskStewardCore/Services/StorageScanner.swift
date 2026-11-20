import Foundation

/// Scans a selected disk or folder recursively, collecting allocated and logical sizes,
/// enforcing symlink & single-volume boundaries, and surfacing inaccessible paths explicitly (REQ-003, plan I-3).
public struct StorageScanner: Sendable {
    public init() {}

    /// macOS XNU kernel portals, virtual filesystems, and firmlink volume containers
    /// that duplicate the root filesystem or do not represent user storage on the scanned disk.
    public static let excludedVirtualPaths: Set<String> = [
        "/.nofollow",
        "/.resolve",
        "/.vol",
        "/dev",
        "/Volumes",
        "/System/Volumes",
        "/net",
        "/home"
    ]

    /// Resource keys fetched during traversal.
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isVolumeKey,
        .fileSizeKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .contentModificationDateKey,
        .volumeIdentifierKey,
        .linkCountKey,
        .fileResourceIdentifierKey
    ]

    /// Returns true if `entryPath` is a macOS virtual/portal path that should not be traversed
    /// unless the user explicitly selected that path (or a descendant of it) as `rootPath`.
    public static func shouldSkipVirtualPath(_ entryPath: String, rootPath: String) -> Bool {
        guard excludedVirtualPaths.contains(entryPath) else { return false }
        if rootPath == entryPath || rootPath.hasPrefix(entryPath + "/") {
            return false
        }
        return true
    }

    /// Scans `rootURL` asynchronously. Reports periodic `ScanProgress` updates and handles Task cancellation gracefully.
    public func scan(
        rootURL: URL,
        stayOnSameVolume: Bool = true,
        progressHandler: (@Sendable (ScanProgress) -> Void)? = nil
    ) async -> ScanResult {
        let start = Date()
        let standardizedRoot = rootURL.standardizedFileURL

        let rootValues = try? standardizedRoot.resourceValues(forKeys: Self.resourceKeys)
        let rootVolumeID = rootValues?.volumeIdentifier as? NSObject

        let state = TraversalState()
        if let rootDirID = Self.identifierData(from: rootValues?.fileResourceIdentifier) {
            state.seenDirectoryIDs.insert(rootDirID)
        }

        let rootNode = traverseDirectory(
            url: standardizedRoot,
            rootPath: standardizedRoot.path,
            rootVolumeID: stayOnSameVolume ? rootVolumeID : nil,
            stayOnSameVolume: stayOnSameVolume,
            state: state,
            progressHandler: progressHandler
        )

        let duration = Date().timeIntervalSince(start)
        return ScanResult(
            root: rootNode,
            scannedAt: Date(),
            duration: duration,
            totalFilesScanned: state.filesScanned,
            totalDirectoriesScanned: state.directoriesScanned,
            wasCancelled: state.wasCancelled,
            issues: state.issues
        )
    }

    private final class TraversalState {
        var filesScanned = 0
        var directoriesScanned = 0
        var bytesAccumulated: Int64 = 0
        var issues: [ScanIssue] = []
        var wasCancelled = false
        var seenHardLinkIDs: Set<Data> = []
        var seenDirectoryIDs: Set<Data> = []
        var lastProgressReport = Date.distantPast
    }

    private static func identifierData(from raw: Any?) -> Data? {
        if let data = raw as? Data { return data }
        if let nsData = raw as? NSData { return nsData as Data }
        if let coding = raw as? NSCoding {
            return try? NSKeyedArchiver.archivedData(withRootObject: coding, requiringSecureCoding: false)
        }
        return nil
    }

    private func traverseDirectory(
        url: URL,
        rootPath: String,
        rootVolumeID: NSObject?,
        stayOnSameVolume: Bool,
        state: TraversalState,
        progressHandler: (@Sendable (ScanProgress) -> Void)?
    ) -> StorageNode {
        if Task.isCancelled {
            state.wasCancelled = true
            return StorageNode(
                name: displayName(for: url),
                path: url.path,
                isDirectory: true,
                allocatedSize: 0,
                logicalSize: 0,
                fileCount: 0,
                modifiedDate: Date.distantPast,
                category: FileCategory.classify(url: url, isDirectory: true),
                children: [],
                hasInaccessibleDescendants: true
            )
        }

        state.directoriesScanned += 1

        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(Self.resourceKeys),
                options: []
            )
        } catch {
            state.issues.append(ScanIssue(path: url.path, reason: error.localizedDescription))
            let dirMod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return StorageNode(
                name: displayName(for: url),
                path: url.path,
                isDirectory: true,
                allocatedSize: 0,
                logicalSize: 0,
                fileCount: 0,
                modifiedDate: dirMod,
                category: FileCategory.classify(url: url, isDirectory: true),
                children: [],
                hasInaccessibleDescendants: true
            )
        }

        var children: [StorageNode] = []
        children.reserveCapacity(entries.count)

        var totalAllocated: Int64 = 0
        var totalLogical: Int64 = 0
        var totalFiles = 0
        var latestModDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
        var hasInaccessible = false

        for entry in entries {
            if Task.isCancelled {
                state.wasCancelled = true
                hasInaccessible = true
                break
            }

            let entryPath = entry.standardizedFileURL.path

            // Prevent macOS kernel portal (/.nofollow, /.resolve, /.vol) and firmlink/mount recursion.
            if Self.shouldSkipVirtualPath(entryPath, rootPath: rootPath) {
                continue
            }

            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: Self.resourceKeys)
            } catch {
                state.issues.append(ScanIssue(path: entryPath, reason: error.localizedDescription))
                hasInaccessible = true
                continue
            }

            // Never follow symbolic links (prevents cycles and double-counting).
            if values.isSymbolicLink == true {
                let linkSize = Int64(values.fileSize ?? 0)
                let mod = values.contentModificationDate ?? Date()
                let node = StorageNode(
                    name: entry.lastPathComponent,
                    path: entryPath,
                    isDirectory: false,
                    allocatedSize: 0,
                    logicalSize: linkSize,
                    fileCount: 1,
                    modifiedDate: mod,
                    category: .other
                )
                children.append(node)
                totalFiles += 1
                state.filesScanned += 1
                continue
            }

            // Skip nested mount points and volume portals (e.g. /.nofollow, /System/Volumes/Data,
            // CoreSimulator volumes, mounted disk images, external drives) when staying on one volume.
            if stayOnSameVolume {
                if values.isVolume == true {
                    continue
                }
                if let rootVol = rootVolumeID, let entryVol = values.volumeIdentifier as? NSObject, !entryVol.isEqual(rootVol) {
                    continue
                }
            }

            if values.isDirectory == true {
                // Guard against directory inode cycles or duplicate firmlink/portal bindings.
                if let dirID = Self.identifierData(from: values.fileResourceIdentifier) {
                    if !state.seenDirectoryIDs.insert(dirID).inserted {
                        continue
                    }
                }

                let childDir = traverseDirectory(
                    url: entry.standardizedFileURL,
                    rootPath: rootPath,
                    rootVolumeID: rootVolumeID,
                    stayOnSameVolume: stayOnSameVolume,
                    state: state,
                    progressHandler: progressHandler
                )
                children.append(childDir)
                totalAllocated += childDir.allocatedSize
                totalLogical += childDir.logicalSize
                totalFiles += childDir.fileCount
                if childDir.modifiedDate > latestModDate {
                    latestModDate = childDir.modifiedDate
                }
                if childDir.hasInaccessibleDescendants {
                    hasInaccessible = true
                }
            } else {
                var allocated = Int64(
                    values.totalFileAllocatedSize
                        ?? values.fileAllocatedSize
                        ?? values.fileSize
                        ?? 0
                )
                let logical = Int64(values.fileSize ?? 0)

                // Deduplicate multi-link hardlinks so physical space is not counted twice.
                if let linkCount = values.linkCount, linkCount > 1,
                   let resIDData = Self.identifierData(from: values.fileResourceIdentifier) {
                    if state.seenHardLinkIDs.contains(resIDData) {
                        allocated = 0
                    } else {
                        state.seenHardLinkIDs.insert(resIDData)
                    }
                }

                let mod = values.contentModificationDate ?? Date()
                let category = FileCategory.classify(url: entry, isDirectory: false)
                let fileNode = StorageNode(
                    name: entry.lastPathComponent,
                    path: entryPath,
                    isDirectory: false,
                    allocatedSize: allocated,
                    logicalSize: logical,
                    fileCount: 1,
                    modifiedDate: mod,
                    category: category
                )
                children.append(fileNode)
                totalAllocated += allocated
                totalLogical += logical
                totalFiles += 1
                state.filesScanned += 1
                state.bytesAccumulated += allocated
                if mod > latestModDate {
                    latestModDate = mod
                }
            }

            if let progressHandler {
                let now = Date()
                if now.timeIntervalSince(state.lastProgressReport) >= 0.12 {
                    state.lastProgressReport = now
                    progressHandler(
                        ScanProgress(
                            currentPath: entryPath,
                            filesScanned: state.filesScanned,
                            directoriesScanned: state.directoriesScanned,
                            bytesAccumulated: state.bytesAccumulated,
                            issuesCount: state.issues.count
                        )
                    )
                }
            }
        }

        children.sort { lhs, rhs in
            if lhs.allocatedSize != rhs.allocatedSize {
                return lhs.allocatedSize > rhs.allocatedSize
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return StorageNode(
            name: displayName(for: url),
            path: url.path,
            isDirectory: true,
            allocatedSize: totalAllocated,
            logicalSize: totalLogical,
            fileCount: totalFiles,
            modifiedDate: latestModDate == Date.distantPast ? Date() : latestModDate,
            category: FileCategory.classify(url: url, isDirectory: true),
            children: children,
            hasInaccessibleDescendants: hasInaccessible
        )
    }

    private func displayName(for url: URL) -> String {
        if url.path == "/" {
            return (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
        }
        return url.lastPathComponent
    }
}
