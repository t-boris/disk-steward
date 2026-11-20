import AppKit
import DiskStewardCore
import SwiftUI

/// Clean 120 FPS single-level-per-view structural treemap rendered via SwiftUI Canvas (REQ-003, DEC-010, DEC-012).
/// Receives ONLY the lightweight direct children of the active folder (never diffs the full disk tree)
/// and holds hover highlight state strictly locally for zero-lag cursor tracking.
struct TreemapView: View {
    let scopeKey: String
    let scopeTotalBytes: Int64
    let children: [StorageNode]
    let selectedNodeID: String?
    let onHover: (StorageNode?) -> Void
    let onSelect: (StorageNode) -> Void
    let onDrillDown: (StorageNode) -> Void
    let onRevealInFinder: (String) -> Void
    let onCleanFolderByRule: (String) -> Void

    @State private var hoveredTileID: String?
    @State private var hoveredTileNode: StorageNode?
    @State private var cachedSize: CGSize = .zero
    @State private var cachedKey: String = ""
    @State private var cachedTiles: [NestedTreemapTile] = []

    private var layoutCacheKey: String {
        "\(scopeKey)|\(scopeTotalBytes)|\(children.count)|\(children.first?.id ?? "")"
    }

    var body: some View {
        GeometryReader { geo in
            let tiles = currentTiles(for: geo.size)

            ZStack {
                Canvas { context, size in
                    let bgRect = CGRect(origin: .zero, size: size)
                    context.fill(Path(bgRect), with: .color(Color(nsColor: .underPageBackgroundColor)))

                    for tile in tiles {
                        drawTile(tile, isHovered: tile.id == hoveredTileID, in: &context)
                    }

                    if let selectedID = selectedNodeID,
                       let sel = tiles.first(where: { $0.node.id == selectedID }) {
                        let r = cgRect(sel.rect).insetBy(dx: 2, dy: 2)
                        context.stroke(
                            Path(roundedRect: r, cornerRadius: 6),
                            with: .color(.white),
                            lineWidth: 2.5
                        )
                    }

                    if let hovID = hoveredTileID,
                       let hov = tiles.first(where: { $0.id == hovID }) {
                        let r = cgRect(hov.rect).insetBy(dx: 1.5, dy: 1.5)
                        context.stroke(
                            Path(roundedRect: r, cornerRadius: 6),
                            with: .color(.white.opacity(0.95)),
                            lineWidth: 2.2
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
                            Button("Open Folder") {
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
                        Text("No matching files with allocated size in this folder.")
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
            .onChange(of: layoutCacheKey) { _, _ in
                recomputeCache(size: geo.size)
            }
        }
    }

    private func computeSingleLevelTiles(for size: CGSize) -> [NestedTreemapTile] {
        let syntheticScope = StorageNode(
            id: scopeKey,
            name: scopeKey,
            path: scopeKey,
            isDirectory: true,
            allocatedSize: max(1, scopeTotalBytes),
            modifiedDate: Date(),
            category: .other,
            children: children
        )
        return TreemapLayout.computeNested(
            scope: syntheticScope,
            in: TreemapRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height)),
            maxDepth: 0,
            maxItemsPerLevel: 50
        )
    }

    private func currentTiles(for size: CGSize) -> [NestedTreemapTile] {
        if cachedSize == size && cachedKey == layoutCacheKey {
            return cachedTiles
        }
        return computeSingleLevelTiles(for: size)
    }

    private func recomputeCache(size: CGSize) {
        guard size.width > 4, size.height > 4 else { return }
        cachedSize = size
        cachedKey = layoutCacheKey
        cachedTiles = computeSingleLevelTiles(for: size)
    }

    private func hitTest(at point: CGPoint, in tiles: [NestedTreemapTile]) -> NestedTreemapTile? {
        let px = Double(point.x)
        let py = Double(point.y)
        for tile in tiles {
            if tile.rect.contains(x: px, y: py) {
                return tile
            }
        }
        return nil
    }

    private func drawTile(_ tile: NestedTreemapTile, isHovered: Bool, in context: inout GraphicsContext) {
        let rect = cgRect(tile.rect).insetBy(dx: 1.75, dy: 1.75)
        guard rect.width >= 1, rect.height >= 1 else { return }

        let corner: CGFloat = min(6, min(rect.width, rect.height) * 0.25)
        let shape = Path(roundedRect: rect, cornerRadius: corner)

        let baseColor: Color = tile.isAggregatedRemainder
            ? Color(red: 0.40, green: 0.43, blue: 0.48)
            : tile.color.swiftUIColor

        context.fill(shape, with: .color(baseColor))
        context.fill(
            shape,
            with: .linearGradient(
                Gradient(colors: [
                    Color.white.opacity(isHovered ? 0.26 : 0.16),
                    Color.clear,
                    Color.black.opacity(0.22)
                ]),
                startPoint: CGPoint(x: rect.minX, y: rect.minY),
                endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
            )
        )
        context.stroke(shape, with: .color(Color.black.opacity(0.28)), lineWidth: 0.85)

        guard rect.width >= 44 && rect.height >= 20 else { return }

        let isLarge = rect.width >= 150 && rect.height >= 76
        let isMedium = rect.width >= 88 && rect.height >= 44

        let titleFontSize: CGFloat = isLarge ? 14.5 : (isMedium ? 12.0 : 10.0)
        let sizeFontSize: CGFloat = isLarge ? 12.5 : (isMedium ? 10.5 : 9.0)
        let metaFontSize: CGFloat = isLarge ? 10.5 : 9.0
        let insetX: CGFloat = isLarge ? 10 : 6
        let insetY: CGFloat = isLarge ? 8 : 4

        let prefix = (tile.node.isDirectory && !tile.isAggregatedRemainder) ? "▸ " : ""
        let titleText = Text("\(prefix)\(tile.node.name)")
            .font(.system(size: titleFontSize, weight: .bold))
            .foregroundStyle(Color.white)
        let resolvedTitle = context.resolve(titleText)

        context.drawLayer { layer in
            layer.clip(to: Path(rect.insetBy(dx: 4, dy: 3)))
            layer.draw(
                resolvedTitle,
                at: CGPoint(x: rect.minX + insetX, y: rect.minY + insetY),
                anchor: .topLeading
            )

            let sizeY = rect.minY + insetY + titleFontSize + (isLarge ? 5 : 3)
            if rect.height >= (isLarge ? 54 : 34) && rect.width >= 58 {
                let sizeStr = ByteFormatting.string(from: tile.node.allocatedSize)
                let pctStr = ByteFormatting.percentString(tile.fractionOfScope)
                let sizeLabel = rect.width >= 120 ? "\(sizeStr)  (\(pctStr))" : sizeStr
                let sizeText = Text(sizeLabel)
                    .font(.system(size: sizeFontSize, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.95))
                let resolvedSize = layer.resolve(sizeText)
                layer.draw(
                    resolvedSize,
                    at: CGPoint(x: rect.minX + insetX, y: sizeY),
                    anchor: .topLeading
                )

                if isLarge && rect.height >= 88 && !tile.isAggregatedRemainder {
                    let metaStr = tile.node.isDirectory
                        ? "\(tile.node.fileCount.formatted()) file(s) • click to open"
                        : tile.node.category.displayName
                    let metaText = Text(metaStr)
                        .font(.system(size: metaFontSize, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.78))
                    let resolvedMeta = layer.resolve(metaText)
                    layer.draw(
                        resolvedMeta,
                        at: CGPoint(x: rect.minX + insetX, y: sizeY + sizeFontSize + 5),
                        anchor: .topLeading
                    )
                }
            }
        }
    }

    private func cgRect(_ r: TreemapRect) -> CGRect {
        CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }
}
