import AppKit
import DiskStewardCore
import SwiftUI

/// High-performance multi-level structural treemap rendered via SwiftUI Canvas (REQ-003, DEC-010).
/// Every nested rectangle is sized strictly proportionally to allocated bytes and colored with
/// vivid contrasting colors so adjacent folders and files stand apart clearly.
struct TreemapView: View {
    let scopeNode: StorageNode
    let selectedNodeID: String?
    let onHover: (StorageNode?) -> Void
    let onSelect: (StorageNode) -> Void
    let onDrillDown: (StorageNode) -> Void
    let onRevealInFinder: (String) -> Void
    let onCleanFolderByRule: (String) -> Void

    @State private var hoveredTileID: String?
    @State private var hoveredTileNode: StorageNode?
    @State private var cachedSize: CGSize = .zero
    @State private var cachedScopeID: String = ""
    @State private var cachedScopeBytes: Int64 = -1
    @State private var cachedScopeFiles: Int = -1
    @State private var cachedTiles: [NestedTreemapTile] = []

    var body: some View {
        GeometryReader { geo in
            let tiles = currentTiles(for: geo.size)

            ZStack {
                Canvas { context, size in
                    let bgRect = CGRect(origin: .zero, size: size)
                    context.fill(Path(bgRect), with: .color(Color(nsColor: .underPageBackgroundColor)))

                    for tile in tiles {
                        drawTile(tile, in: &context)
                    }

                    // Highlight currently selected or hovered tile on top
                    if let selectedID = selectedNodeID,
                       let sel = tiles.last(where: { $0.node.id == selectedID }) {
                        let r = cgRect(sel.rect).insetBy(dx: 1, dy: 1)
                        context.stroke(
                            Path(roundedRect: r, cornerRadius: 3),
                            with: .color(.white),
                            lineWidth: 2.5
                        )
                    }

                    if let hovID = hoveredTileID,
                       let hov = tiles.first(where: { $0.id == hovID }) {
                        let r = cgRect(hov.rect).insetBy(dx: 0.75, dy: 0.75)
                        context.stroke(
                            Path(roundedRect: r, cornerRadius: 3),
                            with: .color(.white.opacity(0.95)),
                            lineWidth: 2.0
                        )
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let hit = hitTest(at: location, in: tiles)
                        if hit?.id != hoveredTileID {
                            hoveredTileID = hit?.id
                            hoveredTileNode = hit?.node
                            onHover(hit?.node)
                        }
                    case .ended:
                        hoveredTileID = nil
                        hoveredTileNode = nil
                        onHover(nil)
                    }
                }
                .gesture(
                    SpatialTapGesture(count: 1).onEnded { value in
                        guard let hit = hitTest(at: value.location, in: tiles),
                              !hit.isAggregatedRemainder else { return }
                        if hit.node.isDirectory {
                            onDrillDown(hit.node)
                        } else {
                            onSelect(hit.node)
                        }
                    }
                )
                .contextMenu {
                    if let target = hoveredTileNode {
                        if target.isDirectory {
                            Button("Open Folder in Treemap") {
                                onDrillDown(target)
                            }
                            Button("Clean This Folder by Rule…") {
                                onCleanFolderByRule(target.path)
                            }
                        } else {
                            let parent = URL(fileURLWithPath: target.path).deletingLastPathComponent().path
                            Button("Clean Containing Folder by Rule…") {
                                onCleanFolderByRule(parent)
                            }
                        }
                        Divider()
                        Button("Reveal in Finder") {
                            onRevealInFinder(target.path)
                        }
                    }
                }

                if tiles.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No matching files with allocated size in this scope.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            )
            .onAppear {
                recomputeCache(size: geo.size)
            }
            .onChange(of: geo.size) { _, newSize in
                recomputeCache(size: newSize)
            }
            .onChange(of: scopeNode.id) { _, _ in
                recomputeCache(size: geo.size)
            }
            .onChange(of: scopeNode.allocatedSize) { _, _ in
                recomputeCache(size: geo.size)
            }
            .onChange(of: scopeNode.fileCount) { _, _ in
                recomputeCache(size: geo.size)
            }
        }
    }

    private func currentTiles(for size: CGSize) -> [NestedTreemapTile] {
        if cachedSize == size
            && cachedScopeID == scopeNode.id
            && cachedScopeBytes == scopeNode.allocatedSize
            && cachedScopeFiles == scopeNode.fileCount {
            return cachedTiles
        }
        return TreemapLayout.computeNested(
            scope: scopeNode,
            in: TreemapRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height)),
            maxDepth: 4,
            maxItemsPerLevel: 50
        )
    }

    private func recomputeCache(size: CGSize) {
        guard size.width > 4, size.height > 4 else { return }
        cachedSize = size
        cachedScopeID = scopeNode.id
        cachedScopeBytes = scopeNode.allocatedSize
        cachedScopeFiles = scopeNode.fileCount
        cachedTiles = TreemapLayout.computeNested(
            scope: scopeNode,
            in: TreemapRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height)),
            maxDepth: 4,
            maxItemsPerLevel: 50
        )
    }

    /// Hit-tests deepest (most specific) tile under cursor, preferring folder header clicks for container folders.
    private func hitTest(at point: CGPoint, in tiles: [NestedTreemapTile]) -> NestedTreemapTile? {
        let px = Double(point.x)
        let py = Double(point.y)
        // Reverse painter's order checks deepest children first.
        for tile in tiles.reversed() {
            if tile.rect.contains(x: px, y: py) {
                return tile
            }
        }
        return nil
    }

    private func drawTile(_ tile: NestedTreemapTile, in context: inout GraphicsContext) {
        let gap: CGFloat = tile.depth == 0 ? 1.0 : 0.6
        let rect = cgRect(tile.rect).insetBy(dx: gap, dy: gap)
        guard rect.width >= 1, rect.height >= 1 else { return }

        let corner: CGFloat = tile.depth == 0 ? 4 : 2
        let shape = Path(roundedRect: rect, cornerRadius: corner)

        let baseColor: Color = tile.isAggregatedRemainder
            ? Color(red: 0.42, green: 0.45, blue: 0.50)
            : tile.color.swiftUIColor

        // Cushion shading: deeper nested folders get slightly richer framing, leaf tiles get a subtle 3D cushion gradient.
        if tile.hasRenderedChildren {
            // Folder frame container (darker saturated header/frame so nested children inside pop cleanly)
            context.fill(shape, with: .color(baseColor.opacity(0.88)))
            context.fill(shape, with: .color(Color.black.opacity(0.26)))
            context.stroke(shape, with: .color(Color.black.opacity(0.45)), lineWidth: tile.depth == 0 ? 1.4 : 0.9)

            // Draw crisp folder header label
            if let hRect = tile.headerRect {
                let headerCG = cgRect(hRect)
                if headerCG.width >= 44 && headerCG.height >= 11 {
                    let sizeStr = ByteFormatting.string(from: tile.node.allocatedSize)
                    let labelStr = headerCG.width >= 135 ? "▸ \(tile.node.name)  (\(sizeStr))" : tile.node.name
                    let fontSize: CGFloat = tile.depth == 0 ? 10.5 : 9.0
                    let text = Text(labelStr)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(Color.white)
                    let resolved = context.resolve(text)
                    context.drawLayer { layer in
                        layer.clip(to: Path(headerCG))
                        layer.draw(
                            resolved,
                            at: CGPoint(x: headerCG.minX + 4, y: headerCG.midY),
                            anchor: .leading
                        )
                    }
                }
            }
        } else {
            // Leaf file or unexpanded compact folder tile: vivid cushion fill
            let lightHighlight = Color.white.opacity(0.20)
            let darkShade = Color.black.opacity(0.22)
            context.fill(shape, with: .color(baseColor))
            context.fill(
                shape,
                with: .linearGradient(
                    Gradient(colors: [lightHighlight, .clear, darkShade]),
                    startPoint: CGPoint(x: rect.minX, y: rect.minY),
                    endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
                )
            )
            context.stroke(shape, with: .color(Color.black.opacity(0.30)), lineWidth: 0.75)

            // Label inside tile when there is enough room
            if rect.width >= 48 && rect.height >= 16 {
                let prefix = tile.node.isDirectory ? "📁 " : ""
                let titleText = Text("\(prefix)\(tile.node.name)")
                    .font(.system(size: rect.width >= 100 ? 10.5 : 9.0, weight: .semibold))
                    .foregroundStyle(Color.white)
                let resolvedTitle = context.resolve(titleText)

                context.drawLayer { layer in
                    layer.clip(to: Path(rect.insetBy(dx: 3, dy: 2)))
                    layer.draw(
                        resolvedTitle,
                        at: CGPoint(x: rect.minX + 4, y: rect.minY + 3),
                        anchor: .topLeading
                    )

                    if rect.height >= 31 && rect.width >= 56 {
                        let sizeLabel = "\(ByteFormatting.string(from: tile.node.allocatedSize))"
                        let subText = Text(sizeLabel)
                            .font(.system(size: 9.0, weight: .regular).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.90))
                        let resolvedSub = layer.resolve(subText)
                        layer.draw(
                            resolvedSub,
                            at: CGPoint(x: rect.minX + 4, y: rect.minY + 16),
                            anchor: .topLeading
                        )
                    }
                }
            }
        }
    }

    private func cgRect(_ r: TreemapRect) -> CGRect {
        CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }
}
