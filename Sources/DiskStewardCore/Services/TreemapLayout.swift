import Foundation

/// Platform-neutral rectangle used by the squarified treemap layout engine.
public struct TreemapRect: Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public var area: Double { width * height }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px <= maxX && py >= y && py <= maxY
    }
}

/// Positioned single-level treemap tile whose area is strictly proportional to `node.allocatedSize` (REQ-003).
public struct TreemapTile: Identifiable, Hashable, Sendable {
    public let id: String
    public let node: StorageNode
    public let rect: TreemapRect
    public let fraction: Double
    public let isAggregatedRemainder: Bool

    public init(
        id: String,
        node: StorageNode,
        rect: TreemapRect,
        fraction: Double,
        isAggregatedRemainder: Bool = false
    ) {
        self.id = id
        self.node = node
        self.rect = rect
        self.fraction = fraction
        self.isAggregatedRemainder = isAggregatedRemainder
    }
}

/// Positioned tile inside a deep recursive structural treemap (DEC-010).
/// Every directory recursively nests its children inside its own rectangle strictly proportional to size,
/// with high-contrast deterministic colors chosen so neighboring tiles and parent/child boxes never collide.
public struct NestedTreemapTile: Identifiable, Hashable, Sendable {
    public let id: String
    public let node: StorageNode
    public let rect: TreemapRect
    public let headerRect: TreemapRect?
    public let depth: Int
    public let fractionOfScope: Double
    public let colorIndex: Int
    public let color: VisualColorSpec
    public let isAggregatedRemainder: Bool
    public let hasRenderedChildren: Bool

    public init(
        id: String,
        node: StorageNode,
        rect: TreemapRect,
        headerRect: TreemapRect?,
        depth: Int,
        fractionOfScope: Double,
        colorIndex: Int,
        color: VisualColorSpec,
        isAggregatedRemainder: Bool = false,
        hasRenderedChildren: Bool = false
    ) {
        self.id = id
        self.node = node
        self.rect = rect
        self.headerRect = headerRect
        self.depth = depth
        self.fractionOfScope = fractionOfScope
        self.colorIndex = colorIndex
        self.color = color
        self.isAggregatedRemainder = isAggregatedRemainder
        self.hasRenderedChildren = hasRenderedChildren
    }
}

/// Curated 16-color vivid structural treemap palette with strong adjacent contrast and crisp white-text legibility.
public enum TreemapPalette {
    public static let colors: [VisualColorSpec] = [
        VisualColorSpec(red: 0.16, green: 0.48, blue: 0.84, hex: "#297AD6", label: "Cobalt", explanation: "Structural tile"),
        VisualColorSpec(red: 0.82, green: 0.31, blue: 0.28, hex: "#D14F47", label: "Coral", explanation: "Structural tile"),
        VisualColorSpec(red: 0.15, green: 0.62, blue: 0.44, hex: "#269E70", label: "Emerald", explanation: "Structural tile"),
        VisualColorSpec(red: 0.82, green: 0.54, blue: 0.12, hex: "#D18A1F", label: "Amber", explanation: "Structural tile"),
        VisualColorSpec(red: 0.54, green: 0.34, blue: 0.78, hex: "#8A57C7", label: "Violet", explanation: "Structural tile"),
        VisualColorSpec(red: 0.08, green: 0.58, blue: 0.66, hex: "#1494A8", label: "Teal", explanation: "Structural tile"),
        VisualColorSpec(red: 0.78, green: 0.28, blue: 0.52, hex: "#C74785", label: "Magenta", explanation: "Structural tile"),
        VisualColorSpec(red: 0.44, green: 0.62, blue: 0.16, hex: "#709E29", label: "Olive", explanation: "Structural tile"),
        VisualColorSpec(red: 0.86, green: 0.41, blue: 0.18, hex: "#DB692E", label: "Tangerine", explanation: "Structural tile"),
        VisualColorSpec(red: 0.25, green: 0.38, blue: 0.78, hex: "#4061C7", label: "Indigo", explanation: "Structural tile"),
        VisualColorSpec(red: 0.16, green: 0.56, blue: 0.50, hex: "#298F80", label: "Seafoam", explanation: "Structural tile"),
        VisualColorSpec(red: 0.74, green: 0.24, blue: 0.36, hex: "#BD3D5C", label: "Crimson", explanation: "Structural tile"),
        VisualColorSpec(red: 0.66, green: 0.46, blue: 0.20, hex: "#A87533", label: "Ochre", explanation: "Structural tile"),
        VisualColorSpec(red: 0.42, green: 0.36, blue: 0.70, hex: "#6B5CB3", label: "Slate Purple", explanation: "Structural tile"),
        VisualColorSpec(red: 0.12, green: 0.52, blue: 0.74, hex: "#1F85BD", label: "Cerulean", explanation: "Structural tile"),
        VisualColorSpec(red: 0.68, green: 0.34, blue: 0.64, hex: "#AD57A3", label: "Plum", explanation: "Structural tile")
    ]

    /// Deterministic FNV-1a 64-bit hash so pseudo-random colors look varied yet stay stable across hover/resize.
    public static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    /// Selects a deterministic vivid color index that avoids matching the parent container OR the immediately adjacent sibling.
    public static func colorIndex(
        for path: String,
        siblingIndex: Int,
        parentColorIndex: Int?,
        previousSiblingColorIndex: Int?
    ) -> Int {
        let count = colors.count
        let base = Int(stableHash(path) % UInt64(count))
        var candidate = (base + siblingIndex * 5) % count
        var attempts = 0
        while attempts < count {
            if candidate != parentColorIndex && candidate != previousSiblingColorIndex {
                return candidate
            }
            candidate = (candidate + 3) % count
            attempts += 1
        }
        return candidate
    }
}

/// Squarified treemap algorithm (Bruls, Huizing & van Wijk) producing proportional rectangles
/// and deep recursive structural nesting (REQ-003, DEC-010).
public enum TreemapLayout {
    /// Computes single-level squarified tiles whose areas are strictly proportional to `node.allocatedSize`.
    public static func compute(
        nodes: [StorageNode],
        in bounds: TreemapRect,
        maxItems: Int = 200
    ) -> [TreemapTile] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }

        let positive = nodes
            .filter { $0.allocatedSize > 0 }
            .sorted { lhs, rhs in
                if lhs.allocatedSize != rhs.allocatedSize {
                    return lhs.allocatedSize > rhs.allocatedSize
                }
                return lhs.name < rhs.name
            }

        guard !positive.isEmpty else { return [] }

        var workingNodes = positive
        var remainderID: String?
        if maxItems > 1 && positive.count > maxItems {
            let head = Array(positive.prefix(maxItems - 1))
            let tail = Array(positive.dropFirst(maxItems - 1))
            let tailAllocated = tail.reduce(Int64(0)) { $0 + $1.allocatedSize }
            let tailLogical = tail.reduce(Int64(0)) { $0 + $1.logicalSize }
            let tailFiles = tail.reduce(0) { $0 + $1.fileCount }
            let latestDate = tail.map(\.modifiedDate).max() ?? Date()
            let syntheticID = "__remainder__:\(tail.count):\(tailAllocated)"
            let remainderNode = StorageNode(
                id: syntheticID,
                name: "\(tail.count) smaller items",
                path: syntheticID,
                isDirectory: false,
                allocatedSize: tailAllocated,
                logicalSize: tailLogical,
                fileCount: tailFiles,
                modifiedDate: latestDate,
                category: .other
            )
            remainderID = syntheticID
            workingNodes = (head + [remainderNode]).sorted { $0.allocatedSize > $1.allocatedSize }
        }

        let totalBytes = workingNodes.reduce(0.0) { $0 + Double($1.allocatedSize) }
        guard totalBytes > 0 else { return [] }

        let totalArea = bounds.area
        let scaled: [(node: StorageNode, area: Double, fraction: Double)] = workingNodes.map { node in
            let frac = Double(node.allocatedSize) / totalBytes
            return (node, frac * totalArea, frac)
        }

        var tiles: [TreemapTile] = []
        tiles.reserveCapacity(scaled.count)
        squarify(
            items: scaled,
            rect: bounds,
            remainderID: remainderID,
            output: &tiles
        )
        return tiles
    }

    /// Computes a multi-level nested structural treemap in painter's order (depth 0 first, deeper descendants later),
    /// assigning distinct contrasting colors to adjacent siblings and nested levels (DEC-010).
    public static func computeNested(
        scope: StorageNode,
        in bounds: TreemapRect,
        maxDepth: Int = 4,
        maxItemsPerLevel: Int = 48
    ) -> [NestedTreemapTile] {
        guard bounds.width > 4, bounds.height > 4 else { return [] }
        let scopeTotalBytes = max(1.0, Double(scope.allocatedSize))
        var result: [NestedTreemapTile] = []
        result.reserveCapacity(256)

        buildNestedLevel(
            nodes: scope.children,
            in: bounds,
            depth: 0,
            maxDepth: max(0, maxDepth),
            maxItemsPerLevel: maxItemsPerLevel,
            scopeTotalBytes: scopeTotalBytes,
            parentColorIndex: nil,
            output: &result
        )
        return result
    }

    private static func buildNestedLevel(
        nodes: [StorageNode],
        in bounds: TreemapRect,
        depth: Int,
        maxDepth: Int,
        maxItemsPerLevel: Int,
        scopeTotalBytes: Double,
        parentColorIndex: Int?,
        output: inout [NestedTreemapTile]
    ) {
        let levelCap = depth == 0 ? maxItemsPerLevel : max(12, maxItemsPerLevel / (depth + 1))
        let flatTiles = compute(nodes: nodes, in: bounds, maxItems: levelCap)
        guard !flatTiles.isEmpty else { return }

        var previousColorIndex: Int?
        for (idx, tile) in flatTiles.enumerated() {
            let colorIdx = TreemapPalette.colorIndex(
                for: tile.node.path,
                siblingIndex: idx,
                parentColorIndex: parentColorIndex,
                previousSiblingColorIndex: previousColorIndex
            )
            previousColorIndex = colorIdx
            let colorSpec = TreemapPalette.colors[colorIdx]
            let scopeFrac = Double(tile.node.allocatedSize) / scopeTotalBytes

            let pad = depth == 0 ? 2.5 : 1.5
            let canNest = tile.node.isDirectory
                && !tile.isAggregatedRemainder
                && depth < maxDepth
                && !tile.node.children.isEmpty
                && tile.rect.width >= 26
                && tile.rect.height >= 24

            let headerHeight: Double
            if canNest && tile.rect.width >= 54 && tile.rect.height >= 36 {
                headerHeight = depth == 0 ? 18.0 : 14.0
            } else {
                headerHeight = 0.0
            }

            let headerRect: TreemapRect? = headerHeight > 0
                ? TreemapRect(
                    x: tile.rect.x + pad,
                    y: tile.rect.y + pad,
                    width: max(0, tile.rect.width - pad * 2),
                    height: headerHeight
                )
                : nil

            let innerRect = TreemapRect(
                x: tile.rect.x + pad,
                y: tile.rect.y + pad + headerHeight,
                width: max(0, tile.rect.width - pad * 2),
                height: max(0, tile.rect.height - pad * 2 - headerHeight)
            )

            let willRenderChildren = canNest && innerRect.width >= 14 && innerRect.height >= 12
            output.append(
                NestedTreemapTile(
                    id: "\(depth):\(tile.id)",
                    node: tile.node,
                    rect: tile.rect,
                    headerRect: headerRect,
                    depth: depth,
                    fractionOfScope: scopeFrac,
                    colorIndex: colorIdx,
                    color: colorSpec,
                    isAggregatedRemainder: tile.isAggregatedRemainder,
                    hasRenderedChildren: willRenderChildren
                )
            )

            if willRenderChildren {
                buildNestedLevel(
                    nodes: tile.node.children,
                    in: innerRect,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    maxItemsPerLevel: maxItemsPerLevel,
                    scopeTotalBytes: scopeTotalBytes,
                    parentColorIndex: colorIdx,
                    output: &output
                )
            }
        }
    }

    private static func squarify(
        items: [(node: StorageNode, area: Double, fraction: Double)],
        rect: TreemapRect,
        remainderID: String?,
        output: inout [TreemapTile]
    ) {
        var remaining = items[...]
        var currentRect = rect

        while !remaining.isEmpty {
            let shortSide = min(currentRect.width, currentRect.height)
            guard shortSide > 0 else { break }

            var row: [(node: StorageNode, area: Double, fraction: Double)] = []
            var rowArea = 0.0

            while let next = remaining.first {
                if row.isEmpty {
                    row.append(next)
                    rowArea += next.area
                    remaining.removeFirst()
                } else {
                    let currentWorst = worstAspectRatio(rowAreas: row.map(\.area), totalRowArea: rowArea, sideLength: shortSide)
                    let candidateAreas = row.map(\.area) + [next.area]
                    let nextWorst = worstAspectRatio(rowAreas: candidateAreas, totalRowArea: rowArea + next.area, sideLength: shortSide)
                    if nextWorst <= currentWorst {
                        row.append(next)
                        rowArea += next.area
                        remaining.removeFirst()
                    } else {
                        break
                    }
                }
            }

            currentRect = layoutRow(
                row: row,
                rowArea: rowArea,
                in: currentRect,
                remainderID: remainderID,
                output: &output
            )
        }
    }

    private static func worstAspectRatio(rowAreas: [Double], totalRowArea: Double, sideLength: Double) -> Double {
        guard !rowAreas.isEmpty, totalRowArea > 0, sideLength > 0 else { return .infinity }
        let s2 = sideLength * sideLength
        let sum2 = totalRowArea * totalRowArea
        var worst = 0.0
        for area in rowAreas where area > 0 {
            let r1 = (s2 * area) / sum2
            let r2 = sum2 / (s2 * area)
            worst = max(worst, max(r1, r2))
        }
        return worst
    }

    private static func layoutRow(
        row: [(node: StorageNode, area: Double, fraction: Double)],
        rowArea: Double,
        in rect: TreemapRect,
        remainderID: String?,
        output: inout [TreemapTile]
    ) -> TreemapRect {
        guard rowArea > 0 else { return rect }

        if rect.width >= rect.height {
            let stripWidth = rect.height > 0 ? min(rect.width, rowArea / rect.height) : 0
            var cursorY = rect.y
            for item in row {
                let itemHeight = stripWidth > 0 ? (item.area / stripWidth) : 0
                let tileRect = TreemapRect(x: rect.x, y: cursorY, width: stripWidth, height: itemHeight)
                output.append(
                    TreemapTile(
                        id: item.node.id,
                        node: item.node,
                        rect: tileRect,
                        fraction: item.fraction,
                        isAggregatedRemainder: item.node.id == remainderID
                    )
                )
                cursorY += itemHeight
            }
            return TreemapRect(
                x: rect.x + stripWidth,
                y: rect.y,
                width: max(0, rect.width - stripWidth),
                height: rect.height
            )
        } else {
            let stripHeight = rect.width > 0 ? min(rect.height, rowArea / rect.width) : 0
            var cursorX = rect.x
            for item in row {
                let itemWidth = stripHeight > 0 ? (item.area / stripHeight) : 0
                let tileRect = TreemapRect(x: cursorX, y: rect.y, width: itemWidth, height: stripHeight)
                output.append(
                    TreemapTile(
                        id: item.node.id,
                        node: item.node,
                        rect: tileRect,
                        fraction: item.fraction,
                        isAggregatedRemainder: item.node.id == remainderID
                    )
                )
                cursorX += itemWidth
            }
            return TreemapRect(
                x: rect.x,
                y: rect.y + stripHeight,
                width: rect.width,
                height: max(0, rect.height - stripHeight)
            )
        }
    }
}
