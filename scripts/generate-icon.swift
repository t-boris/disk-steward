#!/usr/bin/env swift
import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate-icon.swift <output.icns>\n", stderr)
    exit(1)
}

let outputICNS = URL(fileURLWithPath: CommandLine.arguments[1])
let tempIconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("DiskSteward-\(UUID().uuidString).iconset", isDirectory: true)
try FileManager.default.createDirectory(at: tempIconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempIconset) }

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func renderIcon(pixelSize: Int) -> Data? {
    let s = CGFloat(pixelSize)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }

    let margin = s * 0.08
    let cardRect = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let cornerRadius = cardRect.width * 0.22

    // Rounded squircle background with deep slate-blue gradient
    let bgPath = CGPath(roundedRect: cardRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradientColors = [
        CGColor(red: 0.08, green: 0.16, blue: 0.30, alpha: 1.0),
        CGColor(red: 0.11, green: 0.35, blue: 0.56, alpha: 1.0)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: cardRect.minX, y: cardRect.minY),
            end: CGPoint(x: cardRect.maxX, y: cardRect.maxY),
            options: []
        )
    }
    ctx.restoreGState()

    // Subtle border highlight
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
    ctx.setLineWidth(max(1.0, s * 0.012))
    ctx.addPath(bgPath)
    ctx.strokePath()

    // Proportional treemap mosaic inside the icon representing visual storage analysis
    let innerPad = s * 0.19
    let gridW = s - 2 * innerPad
    let gridH = s - 2 * innerPad
    let gap = max(1.0, s * 0.025)
    let tileRadius = max(1.5, s * 0.045)

    let tiles: [(CGRect, CGColor)] = [
        // Large blue tile (left 58%, full height)
        (
            CGRect(x: innerPad, y: innerPad + gridH * 0.28, width: gridW * 0.56 - gap / 2, height: gridH * 0.72),
            CGColor(red: 0.22, green: 0.62, blue: 0.96, alpha: 0.96)
        ),
        // Bottom-left teal drive bar
        (
            CGRect(x: innerPad, y: innerPad, width: gridW, height: gridH * 0.28 - gap),
            CGColor(red: 0.11, green: 0.76, blue: 0.66, alpha: 0.96)
        ),
        // Top-right amber tile
        (
            CGRect(x: innerPad + gridW * 0.56 + gap / 2, y: innerPad + gridH * 0.58 + gap / 2, width: gridW * 0.44 - gap / 2, height: gridH * 0.42 - gap / 2),
            CGColor(red: 0.96, green: 0.67, blue: 0.18, alpha: 0.96)
        ),
        // Mid-right coral tile
        (
            CGRect(x: innerPad + gridW * 0.56 + gap / 2, y: innerPad + gridH * 0.28, width: gridW * 0.44 - gap / 2, height: gridH * 0.30 - gap / 2),
            CGColor(red: 0.92, green: 0.35, blue: 0.32, alpha: 0.96)
        )
    ]

    for (rect, color) in tiles {
        let p = CGPath(roundedRect: rect, cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil)
        ctx.setFillColor(color)
        ctx.addPath(p)
        ctx.fillPath()
    }

    // Small glowing drive status dot on the bottom teal bar
    let dotRadius = max(1.5, s * 0.038)
    let dotCenter = CGPoint(x: innerPad + gridW - dotRadius * 2.5, y: innerPad + (gridH * 0.28 - gap) / 2)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.fillEllipse(in: CGRect(x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for item in sizes {
    guard let png = renderIcon(pixelSize: item.px) else {
        fputs("Failed to render \(item.name)\n", stderr)
        exit(1)
    }
    try png.write(to: tempIconset.appendingPathComponent(item.name))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", tempIconset.path, "-o", outputICNS.path]
try proc.run()
proc.waitUntilExit()
if proc.terminationStatus != 0 {
    fputs("iconutil failed with exit code \(proc.terminationStatus)\n", stderr)
    exit(proc.terminationStatus)
}
