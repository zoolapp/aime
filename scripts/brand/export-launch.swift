#!/usr/bin/env swift
// Outline campaign copy with the same pinned Noto Sans SC font as the brand base.
import AppKit
import CoreText
import CryptoKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let fontURL = root.appendingPathComponent("build/brand-fonts/NotoSansSC.ttf")
let expected = "a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da"
let fontData = try Data(contentsOf: fontURL)
precondition(SHA256.hash(data: fontData).map { String(format: "%02x", $0) }.joined() == expected)
var registrationError: Unmanaged<CFError>?
guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &registrationError) else { fatalError("Cannot register pinned font") }

func outline(_ text: String, size: CGFloat, weight: Double) -> [String: Any] {
    let attributes: [CFString: Any] = [kCTFontNameAttribute: "NotoSansSC-Thin", kCTFontVariationAttribute: [NSNumber(value: 0x77676874): weight]]
    let font = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil)
    precondition((CTFontCopyPostScriptName(font) as String).contains("NotoSansSC"))
    precondition((CTFontCopyVariation(font) as? [NSNumber: NSNumber])?[NSNumber(value: 0x77676874)]?.doubleValue == weight)
    let chars = Array(text.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    precondition(CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count))
    var advances = [CGSize](repeating: .zero, count: chars.count)
    CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, chars.count)
    var x: CGFloat = 0
    var commands: [String] = []
    func n(_ value: CGFloat) -> String { String(format: "%.4f", value) }
    for (index, glyph) in glyphs.enumerated() {
        if let path = CTFontCreatePathForGlyph(font, glyph, nil) {
            path.applyWithBlock { pointer in
                let element = pointer.pointee
                func p(_ i: Int) -> String { "\(n(element.points[i].x + x)) \(n(-element.points[i].y))" }
                switch element.type {
                case .moveToPoint: commands.append("M" + p(0))
                case .addLineToPoint: commands.append("L" + p(0))
                case .addQuadCurveToPoint: commands.append("Q" + p(0) + " " + p(1))
                case .addCurveToPoint: commands.append("C" + p(0) + " " + p(1) + " " + p(2))
                case .closeSubpath: commands.append("Z")
                @unknown default: fatalError("Unknown path element")
                }
            }
        }
        x += advances[index].width
    }
    return ["text": text, "width": x, "size": size, "weight": weight, "d": commands.joined(separator: " ")]
}

let out = root.appendingPathComponent("assets/social/2026-10-01")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let strings: [(String, String, CGFloat, Double)] = [
    ("headline1", "有些话，", 64, 650),
    ("headline2", "适合静静打出来。", 64, 650),
    ("category", "基于 RIME 的开源 macOS 中文输入法", 25, 450),
    ("values", "本地输入  ·  按需 AI  ·  词库订阅更新", 22, 450),
    ("tagline", "中文常新，自在表达。", 22, 450),
    ("url", "aime.zool.app", 22, 500),
    ("preview", "0.1.x 开发预览", 18, 450),
    ("headline1En", "Some words,", 64, 650),
    ("headline2En", "better typed in quiet.", 64, 650),
    ("categoryEn", "Open-source Chinese input for macOS · RIME", 25, 450),
    ("valuesEn", "Local input  ·  Optional AI  ·  Vocabulary feeds", 22, 450),
    ("taglineEn", "New words, freely yours.", 22, 450),
    ("previewEn", "0.1.x Developer preview", 18, 450)
]
var result: [String: Any] = ["fontSHA256": expected]
for (key, text, size, weight) in strings { result[key] = outline(text, size: size, weight: weight) }
try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: out.appendingPathComponent("type-outlines.json"))
print("PASS: \(strings.count) campaign strings outlined from pinned brand font; no missing glyphs")
