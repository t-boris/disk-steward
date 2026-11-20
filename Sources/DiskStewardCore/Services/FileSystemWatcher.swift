import CoreServices
import Foundation

/// Watches macOS directories via FSEvents and reports ONLY real structural or content mutations
/// (create, delete, rename, content modify) so ScanCacheManager can incrementally rescan just
/// the affected subdirectories without rescanning untouched folders (DEC-012).
public final class FileSystemWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.disksteward.fsevents", qos: .utility)
    private var streamRef: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private let onPathsChanged: @Sendable ([String]) -> Void

    private static let ignoredPathSubstrings: [String] = [
        "/.DS_Store",
        "/.Spotlight-V100",
        "/.fseventsd",
        "/.Trashes",
        "/Library/Caches/DiskSteward",
        "/Application Support/DiskSteward",
        "/Library/Caches/com.apple.",
        "/Library/Logs/",
        "/System/Volumes/",
        "/private/var/",
        "/private/tmp/",
        "/dev/"
    ]

    /// FSEvent item flags representing actual size or structure mutations (excludes pure FinderInfo/xattr/inode metadata chatter).
    private static let meaningfulChangeMask: FSEventStreamEventFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated
            | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed
            | kFSEventStreamEventFlagItemModified
            | kFSEventStreamEventFlagItemCloned
            | kFSEventStreamEventFlagMustScanSubDirs
    )

    public init(onPathsChanged: @escaping @Sendable ([String]) -> Void) {
        self.onPathsChanged = onPathsChanged
    }

    deinit {
        stop()
    }

    /// Starts or restarts FSEvents monitoring for the given directory paths.
    public func watch(paths: [String]) {
        let normalized = Array(Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })).sorted()

        lock.lock()
        if normalized == watchedPaths && streamRef != nil {
            lock.unlock()
            return
        }
        stopLocked()
        watchedPaths = normalized
        guard !normalized.isEmpty else {
            lock.unlock()
            return
        }

        let cfPaths = normalized as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagFileEvents
        )

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, eventFlags, _ in
            guard let info = clientCallBackInfo, numEvents > 0 else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            guard let rawPaths = cfArray as? [String] else { return }

            var meaningful: [String] = []
            meaningful.reserveCapacity(min(numEvents, 64))

            for idx in 0..<min(numEvents, rawPaths.count) {
                let flags = eventFlags[idx]
                // Ignore pure metadata-only events (xattr, FinderInfo, Spotlight) that do not alter file sizes or presence.
                guard (flags & FileSystemWatcher.meaningfulChangeMask) != 0 else { continue }

                let path = rawPaths[idx]
                // Ignore synthetic root-only "/" events so OS chatter does not trigger full-disk invalidation.
                if path == "/" || path == "/Volumes" { continue }

                var ignored = false
                for token in FileSystemWatcher.ignoredPathSubstrings {
                    if path.contains(token) {
                        ignored = true
                        break
                    }
                }
                if !ignored {
                    meaningful.append(path)
                }
            }

            if !meaningful.isEmpty {
                watcher.onPathsChanged(meaningful)
            }
        }

        if let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.2, // Coalesce rapid bursts within 1.2s
            flags
        ) {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            streamRef = stream
        }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        stopLocked()
        watchedPaths = []
        lock.unlock()
    }

    private func stopLocked() {
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
    }
}
