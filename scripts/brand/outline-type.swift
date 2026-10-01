#!/usr/bin/env swift
// Outline a small, fixed set of brand text from the pinned Noto Sans SC source.
import AppKit
import CoreText
import CryptoKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let fontURL = root.appendingPathComponent("build/brand-fonts/NotoSansSC.ttf")
let expected = "a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da"
let fontData = try Data(contentsOf: fontURL)
precondition(SHA256.hash(data: fontData).map { String(format: "%02x", $0) }.joined() == expected, "Font checksum differs")
var registrationError: Unmanaged<CFError>?
guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &registrationError) else { fatalError("Cannot register brand font") }

func outline(_ text: String, size: CGFloat, weight: Double, tracking: CGFloat = 0) -> [String: Any] {
    let attrs: [CFString: Any] = [kCTFontNameAttribute: "NotoSansSC-Thin", kCTFontVariationAttribute: [NSNumber(value: 0x77676874): weight]]
    let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
    let font = CTFontCreateWithFontDescriptor(desc, size, nil)
    precondition((CTFontCopyPostScriptName(font) as String).contains("NotoSansSC"), "Unexpected fallback font")
    let variation = CTFontCopyVariation(font) as? [NSNumber: NSNumber]
    precondition(variation?[NSNumber(value: 0x77676874)]?.doubleValue == weight, "Unexpected weight")
    let chars = Array(text.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    precondition(CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count), "Missing glyph")
    var advances = [CGSize](repeating: .zero, count: chars.count)
    CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, chars.count)
    var x: CGFloat = 0
    var commands: [String] = []
    func n(_ v: CGFloat) -> String { String(format: "%.4f", v) }
    for (index, glyph) in glyphs.enumerated() {
        if let path = CTFontCreatePathForGlyph(font, glyph, nil) {
            path.applyWithBlock { pointer in
                let e = pointer.pointee
                func p(_ i: Int) -> String { "\(n(e.points[i].x + x)) \(n(-e.points[i].y))" }
                switch e.type {
                case .moveToPoint: commands.append("M" + p(0))
                case .addLineToPoint: commands.append("L" + p(0))
                case .addQuadCurveToPoint: commands.append("Q" + p(0) + " " + p(1))
                case .addCurveToPoint: commands.append("C" + p(0) + " " + p(1) + " " + p(2))
                case .closeSubpath: commands.append("Z")
                @unknown default: fatalError("Unexpected path element")
                }
            }
        }
        x += advances[index].width + tracking
    }
    return ["text": text, "size": size, "weight": weight, "tracking": tracking, "width": x - tracking,
            "d": commands.joined(separator: " "), "postScriptName": CTFontCopyPostScriptName(font),
            "variation": (CTFontCopyVariation(font) as? [NSNumber: NSNumber])?.mapValues { $0.doubleValue }.map { ["axis": $0.key.intValue, "value": $0.value] } ?? []]
}

let strings: [(String, String, CGFloat, Double, CGFloat)] = [
    ("name", "艾么输入法", 57, 650, 5),
    ("tagline", "中文常新，自在表达。", 32, 400, 0),
    ("boardTitle", "艾么输入法 · 视觉基底", 24, 500, 0),
    ("logoLabel", "标志与字标", 18, 500, 0),
    ("squareLabel", "正方形图标", 18, 500, 0),
    ("menuLabel", "菜单栏单色", 18, 500, 0),
    ("paletteLabel", "朱红 · 纸白 · 墨黑 · 砂金", 18, 500, 0),
    ("patternLabel", "字签图案与留白", 18, 500, 0),
    ("paperLabel", "纸签形象与材质", 18, 500, 0),
    ("smallLabel", "亮暗背景 · 实际像素", 20, 500, 0),
    ("webLabel", "网页与文档封面参照", 18, 500, 0),
    ("socialLabel", "发布卡片参照", 18, 500, 0),
    ("stickerLabel", "头像与贴纸参照", 18, 500, 0)
]
var results: [String: Any] = ["fontSHA256": expected]
for (key, text, size, weight, tracking) in strings { results[key] = outline(text, size: size, weight: weight, tracking: tracking) }
let output = root.appendingPathComponent("assets/brand/aime/base-v1/type-outlines.json")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted]).write(to: output)
print("Outlined \(strings.count) strings; all glyphs from pinned Noto Sans SC; \(output.path)")
