#!/usr/bin/env swift
// Renders AIME's icons: the app icon set (both apps) and the menu-bar template icon.
//   swift scripts/gen-icons.swift
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

// Preserve the source of every exported raster inside PNG metadata. This only adds
// a text chunk; approved artwork (including the 1024px master's IDAT) is untouched.
func withOrigin(_ data: Data, source: String) -> Data {
    let origin = "impeccable:prompt\u{0}Origin: assets/brand/aime/base-v1/\(source), approved soft-bookmark vector export (17e0be2); scripts/gen-icons.swift preserves its artwork and scales only when required."
    var payload = Data("tEXt".utf8)
    payload.append(Data(origin.utf8))
    var crc: UInt32 = 0xFFFFFFFF
    for byte in payload {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0) }
    }
    func bigEndian(_ value: UInt32) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    // A PNG ends with the 12-byte IEND chunk.
    var output = Data(data.dropLast(12))
    output.append(bigEndian(UInt32(payload.count - 4)))
    output.append(payload)
    output.append(bigEndian(crc ^ 0xFFFFFFFF))
    output.append(data.suffix(12))
    return output
}

// The approved master already includes macOS icon padding and its rounded paper base.
// Scale it directly: drawing another frame would introduce a second corner treatment.
let masterURL = root.appendingPathComponent("assets/brand/aime/base-v1/app-icon-candidate.png")
guard let master = NSImage(contentsOf: masterURL) else {
    fatalError("Missing approved brand icon: \(masterURL.path)")
}

func drawAppIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        NSGraphicsContext.current?.imageInterpolation = .high
        master.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                    from: .zero, operation: .copy, fraction: 1)
        return true
    }
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// App icon set.
let iconSet = root.appendingPathComponent("Apps/Shared/Assets.xcassets/AppIcon.appiconset")
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)@\(scale)x.png"
        let data = pixels == 1024 ? try Data(contentsOf: masterURL) : png(drawAppIcon(size: CGFloat(pixels)), pixels: pixels)
        try withOrigin(data, source: "app-icon-candidate.png").write(to: iconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: iconSet.appendingPathComponent("Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.write(to: iconSet.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try withOrigin(png(drawAppIcon(size: 512), pixels: 512), source: "app-icon-candidate.png")
    .write(to: root.appendingPathComponent("assets/icon.png"))

for (set, light, dark) in [("BrandLockup", "lockup-color.png", "lockup-white.png"),
                            ("BrandSquare", "square-black.png", "square-white.png")] {
    for (filename, source) in [("light.png", light), ("dark.png", dark)] {
        let input = root.appendingPathComponent("assets/brand/aime/base-v1/\(source)")
        let output = root.appendingPathComponent("Apps/Shared/Assets.xcassets/\(set).imageset/\(filename)")
        try withOrigin(Data(contentsOf: input), source: source).write(to: output)
    }
}

// The input source icon (「艾」 in a 22×16 pt rounded rectangle) is drawn by
// scripts/gen-input-source-icon.swift; keep its PDF byte-for-byte. The system tints it.
try Data(contentsOf: root.appendingPathComponent("assets/brand/aime/input-source-v2/AIME-ai.pdf"))
    .write(to: root.appendingPathComponent("Apps/AIME/Resources/AIME.pdf"))
print("icons written from approved soft-bookmark brand master")
