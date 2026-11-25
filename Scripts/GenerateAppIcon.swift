#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Camera + folder-path mark on a teal field.
// Small sizes collapse to a rounded square and a shutter disc.

func retinaName(_ points: Int) -> String {
    return "icon_\(points)x\(points)" + "@" + "2x.png"
}

func roundedRect(_ rect: CGRect, corner: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
}

func renderIcon(size: Int) -> CGImage? {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let margin = s * 0.06
    let corner = s * 0.22
    let rect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let path = roundedRect(rect, corner: corner)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    let colors = [
        CGColor(srgbRed: 0.07, green: 0.42, blue: 0.48, alpha: 1),
        CGColor(srgbRed: 0.05, green: 0.28, blue: 0.36, alpha: 1),
        CGColor(srgbRed: 0.04, green: 0.18, blue: 0.26, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.55, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    if let highlight = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            highlight,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.midY),
            options: []
        )
    }
    ctx.restoreGState()

    ctx.setStrokeColor(CGColor(srgbRed: 0.55, green: 0.92, blue: 0.88, alpha: 0.40))
    ctx.setLineWidth(max(1.0, s * 0.012))
    ctx.addPath(path)
    ctx.strokePath()

    // Camera body
    let camW = s * (size < 32 ? 0.52 : 0.50)
    let camH = s * (size < 32 ? 0.34 : 0.32)
    let camRect = CGRect(
        x: rect.midX - camW / 2 - s * 0.04,
        y: rect.midY - camH / 2 - s * 0.02,
        width: camW,
        height: camH
    )
    ctx.setFillColor(CGColor(srgbRed: 0.94, green: 0.98, blue: 0.97, alpha: 0.96))
    ctx.addPath(roundedRect(camRect, corner: s * 0.06))
    ctx.fillPath()

    if size >= 32 {
        // Viewfinder bump
        let bump = CGRect(
            x: camRect.minX + camW * 0.18,
            y: camRect.maxY - s * 0.01,
            width: camW * 0.28,
            height: s * 0.07
        )
        ctx.setFillColor(CGColor(srgbRed: 0.90, green: 0.96, blue: 0.95, alpha: 0.95))
        ctx.addPath(roundedRect(bump, corner: s * 0.02))
        ctx.fillPath()
    }

    // Shutter
    let shutterR = s * (size < 32 ? 0.10 : 0.09)
    let shutterCenter = CGPoint(x: camRect.midX + s * 0.01, y: camRect.midY)
    ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.72, blue: 0.68, alpha: 1))
    ctx.fillEllipse(in: CGRect(
        x: shutterCenter.x - shutterR,
        y: shutterCenter.y - shutterR,
        width: shutterR * 2,
        height: shutterR * 2
    ))
    ctx.setFillColor(CGColor(srgbRed: 0.06, green: 0.22, blue: 0.28, alpha: 1))
    let innerR = shutterR * 0.45
    ctx.fillEllipse(in: CGRect(
        x: shutterCenter.x - innerR,
        y: shutterCenter.y - innerR,
        width: innerR * 2,
        height: innerR * 2
    ))

    if size >= 48 {
        // Folder badge — the “path”
        let folderW = s * 0.26
        let folderH = s * 0.20
        let folder = CGRect(
            x: rect.maxX - folderW - s * 0.10,
            y: rect.minY + s * 0.12,
            width: folderW,
            height: folderH
        )
        ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.74, blue: 0.28, alpha: 1))
        ctx.addPath(roundedRect(folder, corner: s * 0.03))
        ctx.fillPath()

        let tab = CGRect(
            x: folder.minX,
            y: folder.maxY - s * 0.02,
            width: folderW * 0.42,
            height: s * 0.05
        )
        ctx.addPath(roundedRect(tab, corner: s * 0.015))
        ctx.fillPath()
    }

    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not create image destination for \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("Could not write PNG \(url.path)")
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets", isDirectory: true)
let iconset = assets.appendingPathComponent("AppIcon.iconset", isDirectory: true)

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let slots: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

var expectedNames: [String] = []
for slot in slots {
    let name: String
    if slot.scale == 1 {
        name = "icon_\(slot.points)x\(slot.points).png"
    } else {
        name = retinaName(slot.points)
    }
    let px = slot.points * slot.scale
    guard let img = renderIcon(size: px) else {
        fatalError("Failed to render icon size \(px)")
    }
    writePNG(img, to: iconset.appendingPathComponent(name))
    expectedNames.append(name)
    print("  \(name) (\(px)px)")
}

if let master = renderIcon(size: 1024) {
    writePNG(master, to: assets.appendingPathComponent("AppIcon-1024.png"))
}

let written = try FileManager.default.contentsOfDirectory(atPath: iconset.path).sorted()
let expected = Set(expectedNames)
let actual = Set(written)
guard actual == expected, expected.count == 10 else {
    fatalError("Iconset mismatch.\nExpected (\(expected.count)): \(expected.sorted())\nActual (\(actual.count)): \(actual.sorted())")
}

for name in written {
    if name.contains("example.") || !name.hasPrefix("icon_") {
        fatalError("Unexpected icon filename: \(name)")
    }
}

let icnsURL = assets.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(process.terminationStatus)")
}

print("Wrote \(icnsURL.path) (\(written.count) iconset slots)")
for n in written { print("  OK \(n)") }
