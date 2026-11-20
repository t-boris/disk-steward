import Foundation

/// Computes size-based rankings, file-type breakdowns, date/age breakdowns, and filtered trees (REQ-003, REQ-004).
public enum StorageAnalyzer {
    /// Explained date color legend shown alongside date-colored visualizations (REQ-004 AC 3).
    public static var dateColorLegend: [VisualColorSpec] {
        AgeBucket.allCases.map(\.colorSpec)
    }

    /// Explained file category color legend.
    public static var categoryColorLegend: [VisualColorSpec] {
        FileCategory.allCases.map(\.colorSpec)
    }

    /// Returns a filtered copy of `root` where only files matching `filter` remain and folder totals reflect filtered descendants.
    public static func filteredTree(
        _ root: StorageNode,
        filter: StorageFilter,
        relativeTo now: Date = Date()
    ) -> StorageNode? {
        guard filter.isActive else { return root }
        return filterNode(root, filter: filter, relativeTo: now)
    }

    private static func filterNode(
        _ node: StorageNode,
        filter: StorageFilter,
        relativeTo now: Date
    ) -> StorageNode? {
        if !node.isDirectory {
            return filter.matchesFile(node, relativeTo: now) ? node : nil
        }

        var keptChildren: [StorageNode] = []
        var totalAllocated: Int64 = 0
        var totalLogical: Int64 = 0
        var totalFiles = 0
        var latestDate = Date.distantPast

        for child in node.children {
            if let kept = filterNode(child, filter: filter, relativeTo: now) {
                keptChildren.append(kept)
                totalAllocated += kept.allocatedSize
                totalLogical += kept.logicalSize
                totalFiles += kept.fileCount
                if kept.modifiedDate > latestDate {
                    latestDate = kept.modifiedDate
                }
            }
        }

        guard !keptChildren.isEmpty else { return nil }
        keptChildren.sort { $0.allocatedSize > $1.allocatedSize }

        return StorageNode(
            id: node.id,
            name: node.name,
            path: node.path,
            isDirectory: true,
            allocatedSize: totalAllocated,
            logicalSize: totalLogical,
            fileCount: totalFiles,
            modifiedDate: latestDate == Date.distantPast ? node.modifiedDate : latestDate,
            category: node.category,
            children: keptChildren,
            hasInaccessibleDescendants: node.hasInaccessibleDescendants
        )
    }

    /// Returns the largest files (or optionally files & directories) within `scope` matching `filter`.
    public static func largestItems(
        in scope: StorageNode,
        includeDirectories: Bool = false,
        limit: Int = 100,
        filter: StorageFilter = StorageFilter(),
        relativeTo now: Date = Date()
    ) -> [StorageNode] {
        var collected: [StorageNode] = []
        collectItems(
            node: scope,
            isRoot: true,
            includeDirectories: includeDirectories,
            filter: filter,
            now: now,
            into: &collected
        )
        collected.sort { lhs, rhs in
            if lhs.allocatedSize != rhs.allocatedSize {
                return lhs.allocatedSize > rhs.allocatedSize
            }
            return lhs.path < rhs.path
        }
        return Array(collected.prefix(max(0, limit)))
    }

    private static func collectItems(
        node: StorageNode,
        isRoot: Bool,
        includeDirectories: Bool,
        filter: StorageFilter,
        now: Date,
        into result: inout [StorageNode]
    ) {
        if !node.isDirectory {
            if filter.matchesFile(node, relativeTo: now) {
                result.append(node)
            }
            return
        }

        if includeDirectories && !isRoot {
            result.append(node)
        }
        for child in node.children {
            collectItems(
                node: child,
                isRoot: false,
                includeDirectories: includeDirectories,
                filter: filter,
                now: now,
                into: &result
            )
        }
    }

    /// Aggregates matching file storage usage by FileCategory, sorted descending by bytes.
    public static func categoryBreakdown(
        in scope: StorageNode,
        filter: StorageFilter = StorageFilter(),
        relativeTo now: Date = Date()
    ) -> [CategoryBreakdown] {
        var bytesByCategory: [FileCategory: Int64] = [:]
        var countsByCategory: [FileCategory: Int] = [:]
        var grandTotal: Int64 = 0

        walkFiles(in: scope) { file in
            guard filter.matchesFile(file, relativeTo: now) else { return }
            bytesByCategory[file.category, default: 0] += file.allocatedSize
            countsByCategory[file.category, default: 0] += 1
            grandTotal += file.allocatedSize
        }

        return FileCategory.allCases.compactMap { category in
            let count = countsByCategory[category, default: 0]
            guard count > 0 else { return nil }
            let bytes = bytesByCategory[category, default: 0]
            let frac = grandTotal > 0 ? Double(bytes) / Double(grandTotal) : 0
            return CategoryBreakdown(category: category, totalBytes: bytes, fileCount: count, fraction: frac)
        }
        .sorted { $0.totalBytes > $1.totalBytes }
    }

    /// Aggregates matching file storage usage by modification-date AgeBucket, in chronological bucket order.
    public static func ageBreakdown(
        in scope: StorageNode,
        filter: StorageFilter = StorageFilter(),
        relativeTo now: Date = Date()
    ) -> [AgeBreakdown] {
        var bytesByBucket: [AgeBucket: Int64] = [:]
        var countsByBucket: [AgeBucket: Int] = [:]
        var grandTotal: Int64 = 0

        walkFiles(in: scope) { file in
            guard filter.matchesFile(file, relativeTo: now) else { return }
            let bucket = AgeBucket.bucket(for: file.modifiedDate, relativeTo: now)
            bytesByBucket[bucket, default: 0] += file.allocatedSize
            countsByBucket[bucket, default: 0] += 1
            grandTotal += file.allocatedSize
        }

        return AgeBucket.allCases.map { bucket in
            let bytes = bytesByBucket[bucket, default: 0]
            let count = countsByBucket[bucket, default: 0]
            let frac = grandTotal > 0 ? Double(bytes) / Double(grandTotal) : 0
            return AgeBreakdown(bucket: bucket, totalBytes: bytes, fileCount: count, fraction: frac)
        }
    }

    private static func walkFiles(in node: StorageNode, visit: (StorageNode) -> Void) {
        if !node.isDirectory {
            visit(node)
            return
        }
        for child in node.children {
            walkFiles(in: child, visit: visit)
        }
    }
}
