import Foundation

/// Abstraction over mounted volume enumeration for deterministic testing.
public protocol VolumeProvider: Sendable {
    func mountedVolumes(at date: Date) -> [DiskVolume]
}

/// Reads real macOS mounted volumes via FileManager URL resource keys (REQ-002).
public struct SystemVolumeProvider: VolumeProvider {
    public init() {}

    public func mountedVolumes(at date: Date = Date()) -> [DiskVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsBrowsableKey,
            .volumeUUIDStringKey
        ]

        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        var volumes: [DiskVolume] = []
        var seenPaths: Set<String> = []

        for url in urls {
            let path = url.standardizedFileURL.path
            guard !seenPaths.contains(path) else { continue }

            // Exclude internal macOS system helper mounts that are not user storage disks.
            if path.hasPrefix("/System/Volumes/") || path == "/Volumes/Recovery" {
                continue
            }

            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                continue
            }
            if let browsable = values.volumeIsBrowsable, !browsable, path != "/" {
                continue
            }

            let total = Int64(values.volumeTotalCapacity ?? 0)
            guard total > 0 else { continue }

            // On non-APFS volumes (e.g. ExFAT/FAT32), volumeAvailableCapacityForImportantUsage can be 0
            // even when volumeAvailableCapacity reports accurate free space.
            let rawAvail = Int64(values.volumeAvailableCapacity ?? 0)
            let importantAvail = values.volumeAvailableCapacityForImportantUsage ?? 0
            let freeBytes: Int64
            let purgeableBytes: Int64
            if rawAvail > 0 {
                freeBytes = rawAvail
                purgeableBytes = importantAvail > rawAvail ? (importantAvail - rawAvail) : 0
            } else if importantAvail > 0 {
                freeBytes = importantAvail
                purgeableBytes = 0
            } else {
                freeBytes = 0
                purgeableBytes = 0
            }

            let name = values.volumeName ?? (path == "/" ? "Macintosh HD" : url.lastPathComponent)
            let uuid = values.volumeUUIDString
            let id = uuid ?? path

            seenPaths.insert(path)
            volumes.append(
                DiskVolume(
                    id: id,
                    name: name,
                    mountPath: path,
                    uuid: uuid,
                    isMainDisk: path == "/",
                    isInternal: values.volumeIsInternal ?? (path == "/"),
                    isRemovable: values.volumeIsRemovable ?? false,
                    isConnected: true,
                    totalBytes: total,
                    freeBytes: min(freeBytes, total),
                    purgeableBytes: purgeableBytes,
                    lastUpdated: date
                )
            )
        }

        return volumes.sorted { lhs, rhs in
            if lhs.isMainDisk != rhs.isMainDisk { return lhs.isMainDisk }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

/// Tracks live disk space across the main disk and connected additional disks,
/// while preserving disconnected/unavailable disks distinctly without stale measurements (REQ-002, plan I-2).
public final class VolumeMonitor: @unchecked Sendable {
    private let provider: VolumeProvider
    private let lock = NSLock()
    private var knownVolumesByPath: [String: DiskVolume] = [:]
    private var trackedPaths: Set<String> = []

    public init(provider: VolumeProvider = SystemVolumeProvider(), trackedPaths: [String] = []) {
        self.provider = provider
        self.trackedPaths = Set(trackedPaths.map { Self.volumeRootPath(forDestination: $0) })
    }

    /// Registers additional volume paths (such as archive destination roots) so they appear as Unavailable when disconnected.
    public func registerTrackedDestinationPaths(_ paths: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for path in paths where !path.isEmpty {
            let root = Self.volumeRootPath(forDestination: path)
            if root != "/" {
                trackedPaths.insert(root)
            }
        }
    }

    /// Refreshes capacity metrics for all mounted volumes and marks previously known/tracked missing volumes as unavailable.
    public func refresh(at date: Date = Date()) -> [DiskVolume] {
        let connected = provider.mountedVolumes(at: date)

        lock.lock()
        defer { lock.unlock() }

        let connectedByPath = Dictionary(uniqueKeysWithValues: connected.map { ($0.mountPath, $0) })
        var merged: [DiskVolume] = []

        for vol in connected {
            knownVolumesByPath[vol.mountPath] = vol
            merged.append(vol)
        }

        // Preserve previously connected or explicitly tracked external volumes as clearly Unavailable (zero live metrics).
        let candidateOfflinePaths = Set(knownVolumesByPath.keys).union(trackedPaths).subtracting(connectedByPath.keys)
        for path in candidateOfflinePaths.sorted() {
            if let previous = knownVolumesByPath[path] {
                let offline = DiskVolume(
                    id: previous.id,
                    name: previous.name,
                    mountPath: previous.mountPath,
                    uuid: previous.uuid,
                    isMainDisk: previous.isMainDisk,
                    isInternal: previous.isInternal,
                    isRemovable: previous.isRemovable,
                    isConnected: false,
                    totalBytes: 0,
                    freeBytes: 0,
                    purgeableBytes: 0,
                    lastUpdated: previous.lastUpdated
                )
                merged.append(offline)
            } else {
                let name = URL(fileURLWithPath: path).lastPathComponent
                let offline = DiskVolume(
                    id: path,
                    name: name.isEmpty ? path : name,
                    mountPath: path,
                    uuid: nil,
                    isMainDisk: false,
                    isInternal: false,
                    isRemovable: true,
                    isConnected: false,
                    totalBytes: 0,
                    freeBytes: 0,
                    purgeableBytes: 0,
                    lastUpdated: date
                )
                merged.append(offline)
            }
        }

        return merged.sorted { lhs, rhs in
            if lhs.isMainDisk != rhs.isMainDisk { return lhs.isMainDisk }
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Returns the volume mount root for a given path (e.g. "/Volumes/Storage0/Movies" -> "/Volumes/Storage0", else "/").
    public static func volumeRootPath(forDestination path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let components = URL(fileURLWithPath: standardized).pathComponents
        if components.count >= 3 && components[0] == "/" && components[1] == "Volumes" {
            return "/Volumes/\(components[2])"
        }
        return "/"
    }

    /// Checks whether the volume hosting `destinationPath` is currently mounted and accessible.
    public static func isDestinationVolumeAvailable(
        _ destinationPath: String,
        mountedVolumePaths: Set<String>? = nil
    ) -> Bool {
        let root = volumeRootPath(forDestination: destinationPath)
        if let mounted = mountedVolumePaths {
            return mounted.contains(root)
        }
        if root == "/" {
            return FileManager.default.fileExists(atPath: "/")
        }
        // Verify the volume is genuinely mounted (not merely an empty stale directory inside /Volumes).
        let mountedURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        let mountedSet = Set(mountedURLs.map { $0.standardizedFileURL.path })
        return mountedSet.contains(root)
    }
}
