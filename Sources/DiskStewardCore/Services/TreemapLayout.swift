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
}

/// Positioned treemap tile whose area is strictly proportional to `node.allocatedSize` (REQ-003).
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

/// Squarified treemap algorithm (Bruls, Huizing & van Wijk) producing low-aspect-ratio proportional rectangles.
public enum TreemapLayout {
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
            let syntheticID = "__remainder__:\(tail.count)"
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
            // Lay out vertical strip along the left edge.
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
            // Lay out horizontal strip along the top edge.
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
