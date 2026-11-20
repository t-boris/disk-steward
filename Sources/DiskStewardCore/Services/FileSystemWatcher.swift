import CoreServices
import Foundation

/// Watches macOS directories via FSEvents and reports meaningful filesystem mutations
/// so ScanCacheManager can automatically invalidate stale cached storage scans (DEC-012).
public final class FileSystemWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.disksteward.fsevents", qos: .utility)
    private var streamRef: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private let onPathsChanged: @Sendable ([String]) -> Void

    private static let ignoredPathSubstrings: [String] = [
        "/.DS_Store",
        "/Library/Caches/DiskSteward",
        "/Application Support/DiskSteward",
        "/System/Volumes/VM",
        "/private/var/folders",
        "/private/var/vm",
        "/private/var/db",
        "/private/var/log",
        "/dev/"
    ]

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

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, _, _ in
            guard let info = clientCallBackInfo, numEvents > 0 else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            guard let rawPaths = cfArray as? [String] else { return }

            let meaningful = rawPaths.filter { path in
                for ignored in FileSystemWatcher.ignoredPathSubstrings {
                    if path.contains(ignored) { return false }
                }
                return true
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
            1.5, // Coalesce bursts within 1.5s
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
