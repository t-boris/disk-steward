import DiskStewardCore
import SwiftUI

/// Interactive squarified treemap rendering files and folders with areas proportional to their allocated sizes (REQ-003, REQ-004).
struct TreemapView: View {
    let scopeNode: StorageNode
    let colorMode: TreemapColorMode
    let selectedNodeID: String?
    let onHover: (StorageNode?) -> Void
    let onSelect: (StorageNode) -> Void
    let onDrillDown: (StorageNode) -> Void
    let onRevealInFinder: (String) -> Void

    @State private var hoveredTileID: String?

    var body: some View {
        GeometryReader { geo in
            let bounds = TreemapRect(x: 0, y: 0, width: Double(geo.size.width), height: Double(geo.size.height))
            let tiles = TreemapLayout.compute(nodes: scopeNode.children, in: bounds, maxItems: 180)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .underPageBackgroundColor))

                if tiles.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No matching files with allocated size in this scope.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(tiles) { tile in
                        tileView(tile)
                            .frame(
                                width: max(1, CGFloat(tile.rect.width) - 2),
                                height: max(1, CGFloat(tile.rect.height) - 2)
                            )
                            .position(
                                x: CGFloat(tile.rect.x + tile.rect.width / 2),
                                y: CGFloat(tile.rect.y + tile.rect.height / 2)
                            )
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
    }

    private func tileView(_ tile: TreemapTile) -> some View {
        let isHovered = hoveredTileID == tile.id
        let isSelected = selectedNodeID == tile.node.id
        let baseColor = fillColor(for: tile)

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(baseColor.opacity(isHovered ? 0.95 : (tile.node.isDirectory ? 0.80 : 0.88)))

            // Subtle nested preview for folders so directories read visually as containers of items
            if tile.node.isDirectory && tile.rect.width > 95 && tile.rect.height > 54 && !tile.isAggregatedRemainder {
                nestedMiniPreview(for: tile)
            }

            if tile.rect.width >= 66 && tile.rect.height >= 28 {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        if tile.node.isDirectory {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10))
                        }
                        Text(tile.node.name)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    }
                    if tile.rect.height >= 40 {
                        Text("\(ByteFormatting.string(from: tile.node.allocatedSize)) (\(ByteFormatting.percentString(tile.fraction)))")
                            .font(.system(size: 10, weight: .regular).monospacedDigit())
                            .opacity(0.92)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 1)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(
                    isSelected ? Color.white : (isHovered ? Color.white.opacity(0.85) : Color.black.opacity(0.22)),
                    lineWidth: isSelected ? 2.5 : (isHovered ? 1.8 : 0.75)
                )
        )
        .onHover { hovering in
            if hovering {
                hoveredTileID = tile.id
                onHover(tile.node)
            } else if hoveredTileID == tile.id {
                hoveredTileID = nil
                onHover(nil)
            }
        }
        .onTapGesture {
            if tile.isAggregatedRemainder { return }
            if tile.node.isDirectory {
                onDrillDown(tile.node)
            } else {
                onSelect(tile.node)
            }
        }
        .contextMenu {
            if !tile.isAggregatedRemainder {
                if tile.node.isDirectory {
                    Button("Open Folder in Treemap") {
                        onDrillDown(tile.node)
                    }
                }
                Button("Reveal in Finder") {
                    onRevealInFinder(tile.node.path)
                }
            }
        }
    }

    @ViewBuilder
    private func nestedMiniPreview(for tile: TreemapTile) -> some View {
        let insetW = max(0, tile.rect.width - 10)
        let insetH = max(0, tile.rect.height - 34)
        if insetW > 40 && insetH > 18 {
            let subTiles = TreemapLayout.compute(
                nodes: tile.node.children,
                in: TreemapRect(x: 0, y: 0, width: insetW, height: insetH),
                maxItems: 14
            )
            ZStack(alignment: .topLeading) {
                ForEach(subTiles) { sub in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fillColor(for: sub).opacity(0.65))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
                        )
                        .frame(
                            width: max(1, CGFloat(sub.rect.width) - 1),
                            height: max(1, CGFloat(sub.rect.height) - 1)
                        )
                        .position(
                            x: CGFloat(sub.rect.x + sub.rect.width / 2),
                            y: CGFloat(sub.rect.y + sub.rect.height / 2)
                        )
                }
            }
            .frame(width: CGFloat(insetW), height: CGFloat(insetH))
            .offset(x: 5, y: 29)
            .allowsHitTesting(false)
        }
    }

    private func fillColor(for tile: TreemapTile) -> Color {
        if tile.isAggregatedRemainder {
            return Color.gray
        }
        switch colorMode {
        case .byDateAge:
            return tile.node.ageBucket().colorSpec.swiftUIColor
        case .byFileType:
            if tile.node.isDirectory {
                if let dominant = dominantCategory(for: tile.node) {
                    return dominant.colorSpec.swiftUIColor
                }
                return Color(red: 0.34, green: 0.44, blue: 0.56)
            }
            return tile.node.category.colorSpec.swiftUIColor
        }
    }

    private func dominantCategory(for folder: StorageNode) -> FileCategory? {
        guard let largestChild = folder.children.first else { return nil }
        return largestChild.isDirectory ? nil : largestChild.category
    }
}
