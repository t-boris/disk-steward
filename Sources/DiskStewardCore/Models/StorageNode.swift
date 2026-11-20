import Foundation

/// High-level file classification used for storage breakdowns, filters, and archive routing.
public enum FileCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case images
    case videos
    case audio
    case documents
    case archives
    case installers
    case code
    case cachesAndLogs
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .images: return "Images"
        case .videos: return "Videos"
        case .audio: return "Audio"
        case .documents: return "Documents"
        case .archives: return "Archives"
        case .installers: return "Installers"
        case .code: return "Code & Projects"
        case .cachesAndLogs: return "Caches & Logs"
        case .other: return "Other"
        }
    }

    public var systemImage: String {
        switch self {
        case .images: return "photo"
        case .videos: return "film"
        case .audio: return "music.note"
        case .documents: return "doc.text"
        case .archives: return "archivebox"
        case .installers: return "shippingbox"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .cachesAndLogs: return "tray.full"
        case .other: return "doc"
        }
    }

    public var colorSpec: VisualColorSpec {
        switch self {
        case .images:
            return VisualColorSpec(red: 0.22, green: 0.56, blue: 0.94, hex: "#388FF0", label: displayName, explanation: "Photos, illustrations, and raster/vector graphics")
        case .videos:
            return VisualColorSpec(red: 0.58, green: 0.34, blue: 0.88, hex: "#9457E0", label: displayName, explanation: "Movies, screen recordings, and video clips")
        case .audio:
            return VisualColorSpec(red: 0.90, green: 0.31, blue: 0.56, hex: "#E64F8F", label: displayName, explanation: "Music, podcasts, and audio recordings")
        case .documents:
            return VisualColorSpec(red: 0.14, green: 0.65, blue: 0.54, hex: "#24A68A", label: displayName, explanation: "PDFs, office files, ebooks, and notes")
        case .archives:
            return VisualColorSpec(red: 0.85, green: 0.55, blue: 0.14, hex: "#D98C24", label: displayName, explanation: "Compressed archives and tarballs")
        case .installers:
            return VisualColorSpec(red: 0.86, green: 0.32, blue: 0.25, hex: "#DB5240", label: displayName, explanation: "Disk images, installers, and packages")
        case .code:
            return VisualColorSpec(red: 0.23, green: 0.69, blue: 0.36, hex: "#3BB05C", label: displayName, explanation: "Source code, configs, and build scripts")
        case .cachesAndLogs:
            return VisualColorSpec(red: 0.63, green: 0.58, blue: 0.44, hex: "#A19470", label: displayName, explanation: "Logs, caches, and temporary artifacts")
        case .other:
            return VisualColorSpec(red: 0.50, green: 0.54, blue: 0.60, hex: "#808A99", label: displayName, explanation: "Uncategorized and binary files")
        }
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg",
        "ico", "psd", "raw", "dng", "cr2", "cr3", "nef", "arw", "avif"
    ]
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "mkv", "avi", "wmv", "flv", "webm", "m4v", "mpg", "mpeg", "3gp", "ts", "mts"
    ]
    private static let audioExtensions: Set<String> = [
        "mp3", "wav", "aac", "flac", "m4a", "ogg", "wma", "aiff", "aif", "opus", "alac", "midi", "mid"
    ]
    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
        "txt", "rtf", "rtfd", "md", "markdown", "csv", "tsv", "epub", "mobi", "odt", "ods", "odp"
    ]
    private static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst", "lz4", "cab"
    ]
    private static let installerExtensions: Set<String> = [
        "dmg", "pkg", "mpkg", "iso", "xip", "msi", "exe", "deb", "rpm", "appimage", "ipa", "apk"
    ]
    private static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "rs", "go", "py", "js", "jsx", "ts", "tsx",
        "java", "kt", "kts", "rb", "php", "cs", "sh", "zsh", "bash", "fish", "html", "htm", "css",
        "scss", "sass", "less", "json", "yaml", "yml", "toml", "xml", "sql", "graphql", "proto",
        "dockerfile", "makefile", "gradle", "plist", "pbxproj", "xcconfig"
    ]
    private static let cacheLogExtensions: Set<String> = [
        "log", "cache", "tmp", "temp", "swp", "bak", "dmp", "crash", "ips"
    ]

    private static let extensionLookup: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        for e in installerExtensions { map[e] = .installers }
        for e in imageExtensions { map[e] = .images }
        for e in videoExtensions { map[e] = .videos }
        for e in audioExtensions { map[e] = .audio }
        for e in archiveExtensions { map[e] = .archives }
        for e in documentExtensions { map[e] = .documents }
        for e in codeExtensions { map[e] = .code }
        for e in cacheLogExtensions { map[e] = .cachesAndLogs }
        // Additional common extensions to avoid LaunchServices UTType XPC overhead on large disk scans.
        for e in ["phtml", "vue", "svelte", "astro", "mjs", "cjs", "mts", "cts", "lua", "pl", "pm", "r", "scala", "dart", "ex", "exs", "erl", "zig", "nim", "v", "sol", "tf", "hcl", "ini", "cfg", "conf", "env", "lock", "cmake", "ninja", "bazel", "bzl"] {
            map[e] = .code
        }
        for e in ["m4v", "vob", "ogv", "rmvb", "f4v", "asf", "dv"] { map[e] = .videos }
        for e in ["caf", "amr", "au", "ra", "wv", "ape", "dsf"] { map[e] = .audio }
        for e in ["eps", "ai", "sketch", "fig", "xcf", "jxl", "jp2", "exr", "hdr", "icns"] { map[e] = .images }
        for e in ["war", "ear", "jar", "cpio", "lzma", "lz", "sit", "sitx", "ace", "arj"] { map[e] = .archives }
        for e in ["tex", "bib", "djvu", "fb2", "azw", "azw3", "chm", "rst", "adoc", "org"] { map[e] = .documents }
        return map
    }()

    /// Fast pure-memory file classification avoiding LaunchServices XPC overhead during full-disk scans.
    public static func classify(url: URL, isDirectory: Bool = false) -> FileCategory {
        classify(fileName: url.lastPathComponent, path: url.path, isDirectory: isDirectory)
    }

    public static func classify(fileName: String, path: String, isDirectory: Bool = false) -> FileCategory {
        if isDirectory {
            let lower = fileName.lowercased()
            if lower == "caches" || lower == "cache" || lower == ".cache" || lower == "deriveddata" {
                return .cachesAndLogs
            }
            return .other
        }

        let ext = (fileName as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let matched = extensionLookup[ext] {
            return matched
        }

        let lowerName = fileName.lowercased()
        if lowerName == "dockerfile" || lowerName == "makefile" || lowerName == "gemfile" || lowerName == "podfile" || lowerName == "rakefile" {
            return .code
        }

        if path.contains("/Caches/") || path.contains("/Logs/") || path.contains("/caches/") || path.contains("/logs/") {
            return .cachesAndLogs
        }

        return .other
    }
}

/// Platform-neutral RGB + hex + explanation metadata for visual legends.
public struct VisualColorSpec: Hashable, Codable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let hex: String
    public let label: String
    public let explanation: String

    public init(red: Double, green: Double, blue: Double, hex: String, label: String, explanation: String) {
        self.red = red
        self.green = green
        self.blue = blue
        self.hex = hex
        self.label = label
        self.explanation = explanation
    }
}

/// Age buckets based on file modification date, paired with explained visual colors (REQ-004).
public enum AgeBucket: String, CaseIterable, Codable, Sendable, Identifiable {
    case within7Days
    case days7To30
    case months1To6
    case months6To12
    case over1Year

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .within7Days: return "< 7 days"
        case .days7To30: return "7–30 days"
        case .months1To6: return "1–6 months"
        case .months6To12: return "6–12 months"
        case .over1Year: return "> 1 year"
        }
    }

    public var colorSpec: VisualColorSpec {
        switch self {
        case .within7Days:
            return VisualColorSpec(
                red: 0.15, green: 0.45, blue: 0.92, hex: "#2673EB",
                label: displayName,
                explanation: "Modified within the last 7 days (most recent)"
            )
        case .days7To30:
            return VisualColorSpec(
                red: 0.06, green: 0.62, blue: 0.56, hex: "#0F9E8F",
                label: displayName,
                explanation: "Modified between 7 and 30 days ago"
            )
        case .months1To6:
            return VisualColorSpec(
                red: 0.16, green: 0.66, blue: 0.34, hex: "#29A857",
                label: displayName,
                explanation: "Modified between 1 and 6 months ago"
            )
        case .months6To12:
            return VisualColorSpec(
                red: 0.88, green: 0.56, blue: 0.08, hex: "#E08F14",
                label: displayName,
                explanation: "Modified between 6 and 12 months ago (aging)"
            )
        case .over1Year:
            return VisualColorSpec(
                red: 0.85, green: 0.25, blue: 0.22, hex: "#D94038",
                label: displayName,
                explanation: "Modified over 1 year ago (oldest / prime archival or cleanup candidates)"
            )
        }
    }

    /// Categorizes a modification date relative to a reference date.
    public static func bucket(for date: Date, relativeTo referenceDate: Date = Date()) -> AgeBucket {
        let ageSeconds = max(0, referenceDate.timeIntervalSince(date))
        let days = ageSeconds / 86_400.0
        if days < 7 { return .within7Days }
        if days < 30 { return .days7To30 }
        if days < 180 { return .months1To6 }
        if days < 365 { return .months6To12 }
        return .over1Year
    }
}

/// Non-fatal issue encountered while scanning a directory or file (e.g., permission denied).
public struct ScanIssue: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let path: String
    public let reason: String

    public init(id: UUID = UUID(), path: String, reason: String) {
        self.id = id
        self.path = path
        self.reason = reason
    }
}

/// Recursive file or directory tree node returned by StorageScanner.
/// Uses immutable reference semantics with O(1) Equatable/Hashable so SwiftUI never performs
/// deep million-node structural comparisons on the Main Thread (DEC-012).
public final class StorageNode: Identifiable, Hashable, Codable, @unchecked Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let isDirectory: Bool
    /// Allocated on-disk size in bytes (primary size measure for treemap and breakdowns).
    public let allocatedSize: Int64
    /// Logical byte length of the file(s).
    public let logicalSize: Int64
    public let fileCount: Int
    /// Last modification date (for folders, the latest modification date among descendants or self).
    public let modifiedDate: Date
    public let category: FileCategory
    public let children: [StorageNode]
    public let hasInaccessibleDescendants: Bool

    public init(
        id: String? = nil,
        name: String,
        path: String,
        isDirectory: Bool,
        allocatedSize: Int64,
        logicalSize: Int64? = nil,
        fileCount: Int = 1,
        modifiedDate: Date,
        category: FileCategory,
        children: [StorageNode] = [],
        hasInaccessibleDescendants: Bool = false
    ) {
        self.id = id ?? path
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.allocatedSize = max(0, allocatedSize)
        self.logicalSize = max(0, logicalSize ?? allocatedSize)
        self.fileCount = max(0, fileCount)
        self.modifiedDate = modifiedDate
        self.category = category
        self.children = children
        self.hasInaccessibleDescendants = hasInaccessibleDescendants
    }

    /// O(1) equality check (never traverses descendants).
    public static func == (lhs: StorageNode, rhs: StorageNode) -> Bool {
        if lhs === rhs { return true }
        return lhs.id == rhs.id
            && lhs.allocatedSize == rhs.allocatedSize
            && lhs.fileCount == rhs.fileCount
            && lhs.modifiedDate == rhs.modifiedDate
            && lhs.isDirectory == rhs.isDirectory
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(allocatedSize)
        hasher.combine(fileCount)
    }

    public func ageBucket(relativeTo referenceDate: Date = Date()) -> AgeBucket {
        AgeBucket.bucket(for: modifiedDate, relativeTo: referenceDate)
    }

    /// Finds a descendant node by path (including self) in O(depth).
    public func findNode(at targetPath: String) -> StorageNode? {
        if path == targetPath { return self }
        for child in children {
            if targetPath == child.path || targetPath.hasPrefix(child.path + "/") || child.path == "/" {
                if let found = child.findNode(at: targetPath) {
                    return found
                }
            }
        }
        return nil
    }

    /// Returns a new tree with the node at `targetPath` replaced by `replacement` (or removed if `replacement == nil`),
    /// touching ONLY the O(depth) ancestor chain and preserving all untouched sibling StorageNode references intact (DEC-012).
    public func replacingSubtree(at targetPath: String, with replacement: StorageNode?) -> StorageNode {
        let stdTarget = URL(fileURLWithPath: targetPath).standardizedFileURL.path
        let stdSelf = URL(fileURLWithPath: path).standardizedFileURL.path

        if stdSelf == stdTarget {
            return replacement ?? StorageNode(
                id: id,
                name: name,
                path: path,
                isDirectory: isDirectory,
                allocatedSize: 0,
                logicalSize: 0,
                fileCount: 0,
                modifiedDate: Date(),
                category: category,
                children: [],
                hasInaccessibleDescendants: false
            )
        }

        // Only descend if targetPath lies inside this directory.
        let isAncestor = (stdSelf == "/") ? stdTarget.hasPrefix("/") : stdTarget.hasPrefix(stdSelf + "/")
        guard isDirectory && isAncestor else { return self }

        var newChildren = children
        var modified = false

        // Check if target is a direct child first.
        if let directIdx = newChildren.firstIndex(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == stdTarget }) {
            if let replacement {
                newChildren[directIdx] = replacement
            } else {
                newChildren.remove(at: directIdx)
            }
            modified = true
        } else {
            // Check if target lies inside one of our child directories.
            for idx in newChildren.indices where newChildren[idx].isDirectory {
                let childStd = URL(fileURLWithPath: newChildren[idx].path).standardizedFileURL.path
                if stdTarget.hasPrefix(childStd + "/") {
                    let updatedChild = newChildren[idx].replacingSubtree(at: stdTarget, with: replacement)
                    if updatedChild !== newChildren[idx] {
                        newChildren[idx] = updatedChild
                        modified = true
                    }
                    break
                }
            }

            // If target was a newly created direct child directory/file inside stdSelf, insert it!
            if !modified, let replacement {
                let parentOfTarget = URL(fileURLWithPath: stdTarget).deletingLastPathComponent().standardizedFileURL.path
                if parentOfTarget == stdSelf {
                    newChildren.append(replacement)
                    modified = true
                }
            }
        }

        guard modified else { return self }

        newChildren.sort { lhs, rhs in
            if lhs.allocatedSize != rhs.allocatedSize {
                return lhs.allocatedSize > rhs.allocatedSize
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        var totalAllocated: Int64 = 0
        var totalLogical: Int64 = 0
        var totalFiles = 0
        var latestMod = Date.distantPast
        var hasInaccessible = false

        for child in newChildren {
            totalAllocated += child.allocatedSize
            totalLogical += child.logicalSize
            totalFiles += child.fileCount
            if child.modifiedDate > latestMod { latestMod = child.modifiedDate }
            if child.hasInaccessibleDescendants { hasInaccessible = true }
        }

        return StorageNode(
            id: id,
            name: name,
            path: path,
            isDirectory: true,
            allocatedSize: totalAllocated,
            logicalSize: totalLogical,
            fileCount: totalFiles,
            modifiedDate: latestMod == Date.distantPast ? modifiedDate : latestMod,
            category: category,
            children: newChildren,
            hasInaccessibleDescendants: hasInaccessible
        )
    }
}

/// Complete or partial result of scanning a disk or folder.
public struct ScanResult: Codable, Sendable {
    public let root: StorageNode
    public let scannedAt: Date
    public let duration: TimeInterval
    public let totalFilesScanned: Int
    public let totalDirectoriesScanned: Int
    public let wasCancelled: Bool
    public let issues: [ScanIssue]

    public static let sizeMeasureDescription = "Allocated on-disk size (block allocation)"
    public static let dateFieldDescription = "Last modified date"

    public init(
        root: StorageNode,
        scannedAt: Date = Date(),
        duration: TimeInterval,
        totalFilesScanned: Int,
        totalDirectoriesScanned: Int,
        wasCancelled: Bool = false,
        issues: [ScanIssue] = []
    ) {
        self.root = root
        self.scannedAt = scannedAt
        self.duration = duration
        self.totalFilesScanned = totalFilesScanned
        self.totalDirectoriesScanned = totalDirectoriesScanned
        self.wasCancelled = wasCancelled
        self.issues = issues
    }

    /// True only when the scan completed without cancellation and without inaccessible items.
    public var isComplete: Bool {
        !wasCancelled && issues.isEmpty
    }
}

/// Live progress snapshot reported while StorageScanner is traversing.
public struct ScanProgress: Sendable {
    public let currentPath: String
    public let filesScanned: Int
    public let directoriesScanned: Int
    public let bytesAccumulated: Int64
    public let issuesCount: Int

    public init(
        currentPath: String,
        filesScanned: Int,
        directoriesScanned: Int,
        bytesAccumulated: Int64,
        issuesCount: Int
    ) {
        self.currentPath = currentPath
        self.filesScanned = filesScanned
        self.directoriesScanned = directoriesScanned
        self.bytesAccumulated = bytesAccumulated
        self.issuesCount = issuesCount
    }
}
