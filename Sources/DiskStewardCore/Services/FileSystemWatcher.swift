import CoreServices
import Foundation

/// Watches macOS directories via FSEvents and reports ONLY real user-meaningful structural or content
/// mutations (create, delete, rename, modify), aggressively filtering out OS and background-app
/// runtime/cache/WAL chatter so dirty-folder tracking stays quiet and accurate (DEC-012).
public final class FileSystemWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.disksteward.fsevents", qos: .utility)
    private var streamRef: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private let onPathsChanged: @Sendable ([String]) -> Void

    /// High-frequency background runtime/cache/database paths that mutate continuously while apps run
    /// (browsers, chat apps, IDEs, AI assistants, macOS daemons) and should not flood dirty-folder state.
    public static let ignoredPathSubstrings: [String] = [
        "/.DS_Store",
        "/.Spotlight-V100",
        "/.fseventsd",
        "/.Trashes",
        "/.Trash/",
        "/.gemini/",
        "/.dde/",
        "/.claude/",
        "/.codex/",
        "/.ollama/",
        "/.npm/",
        "/.cache/",
        "/Library/Caches/",
        "/Library/Logs/",
        "/Library/Saved Application State/",
        "/Library/HTTPStorages/",
        "/Library/Cookies/",
        "/Library/Preferences/",
        "/Library/Metadata/",
        "/Library/Biome/",
        "/Library/Suggestions/",
        "/Library/WebKit/",
        "/Library/Containers/",
        "/Library/Group Containers/",
        "/Library/Application Support/DiskSteward",
        "/Library/Application Support/Google/Chrome",
        "/Library/Application Support/Microsoft",
        "/Library/Application Support/Slack",
        "/Library/Application Support/Discord",
        "/Library/Application Support/Spotify",
        "/Library/Application Support/Code",
        "/Library/Application Support/Cursor",
        "/Library/Application Support/Obsidian",
        "/Library/Application Support/Claude",
        "/Library/Application Support/ChatGPT",
        "/Library/Application Support/com.apple.",
        "/Library/Application Support/CrashReporter",
        "/System/Volumes/",
        "/private/var/",
        "/private/tmp/",
        "/dev/"
    ]

    /// Ephemeral database WAL/SHM/temp/lock suffixes that constantly churn during normal app usage.
    private static let ignoredFileSuffixes: [String] = [
        "-wal",
        "-shm",
        "-journal",
        ".tmp",
        ".temp",
        ".crswap",
        ".crdownload",
        ".lock",
        ".lck",
        ".swp",
        ".part"
    ]

    /// FSEvent item flags representing actual size or structure mutations (excludes pure FinderInfo/xattr/inode metadata chatter).
    private static let meaningfulChangeMask: FSEventStreamEventFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated
            | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed
            | kFSEventStreamEventFlagItemModified
            | kFSEventStreamEventFlagItemCloned
    )

    public init(onPathsChanged: @escaping @Sendable ([String]) -> Void) {
        self.onPathsChanged = onPathsChanged
    }

    deinit {
        stop()
    }

    /// Returns true if `path` is high-frequency background runtime/cache/WAL chatter that should be ignored by FSEvents.
    public static func shouldIgnorePath(_ path: String) -> Bool {
        if path == "/" || path == "/Volumes" { return true }
        let lower = path.lowercased()
        for suffix in ignoredFileSuffixes {
            if lower.hasSuffix(suffix) { return true }
        }
        for token in ignoredPathSubstrings {
            if path.contains(token) { return true }
        }
        return false
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
                // Ignore pure metadata-only events (xattr, FinderInfo, Spotlight) and kernel overflow flags.
                guard (flags & FileSystemWatcher.meaningfulChangeMask) != 0 else { continue }

                let path = rawPaths[idx]
                if !FileSystemWatcher.shouldIgnorePath(path) {
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
            1.5,
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
