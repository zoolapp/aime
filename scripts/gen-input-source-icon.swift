#!/usr/bin/env swift
// Renders the input source (menu bar) icon: 「艾」 knocked out of a 22×16 pt rounded
// rectangle, the shape macOS uses for its own input sources. The glyph outline comes
// from Noto Sans SC (SIL OFL 1.1), the brand typeface; the font is not kept in the repo.
//   swift scripts/gen-input-source-icon.swift <NotoSansSC[wght].ttf>
// Writes assets/brand/aime/input-source-v2/AIME-ai.{pdf,svg} and Apps/AIME/Resources/AIME.pdf.
import AppKit
import CoreText
import CryptoKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fontSHA256 = "a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da" // assets/brand/aime/base-v1/font-source.json
guard CommandLine.arguments.count == 2 else { fatalError("usage: gen-input-source-icon.swift <NotoSansSC[wght].ttf>") }
let fontURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fontData = try Data(contentsOf: fontURL)
let digest = SHA256.hash(data: fontData).map { String(format: "%02x", $0) }.joined()
guard digest == fontSHA256 else { fatalError("font SHA-256 \(digest) does not match the brand font \(fontSHA256)") }

let width: CGFloat = 22, height: CGFloat = 16, radius: CGFloat = 3.5
let weight: CGFloat = 650 // brand name weight
let glyphSize: CGFloat = 12.5

guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(fontData as CFData) as? [CTFontDescriptor],
      let base = descriptors.first else { fatalError("cannot read font") }
let wght = 0x7767_6874 // 'wght'
let descriptor = CTFontDescriptorCreateCopyWithAttributes(base, [kCTFontVariationAttribute: [wght: weight]] as CFDictionary)
let font = CTFontCreateWithFontDescriptor(descriptor, glyphSize, nil)
var character: UniChar = 0x827E // 艾
var glyph: CGGlyph = 0
guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0,
      let outline = CTFontCreatePathForGlyph(font, glyph, nil) else { fatalError("艾 is missing from the font") }
// Centre the glyph's ink, not its advance box, so it sits optically in the middle.
let ink = outline.boundingBoxOfPath
let centred = outline.copy(using: [CGAffineTransform(translationX: (width - ink.width) / 2 - ink.minX,
                                                    y: (height - ink.height) / 2 - ink.minY)])!
let frame = CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: radius, cornerHeight: radius, transform: nil)
// Variable-font glyphs are built from overlapping strokes: merge them (non-zero) before
// cutting, or an even-odd fill would punch holes where the strokes cross.
let icon = frame.subtracting(centred, using: .winding)

let directory = root.appendingPathComponent("assets/brand/aime/input-source-v2")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

// PDF: one black fill; the system tints it as a template image.
let pdfURL = directory.appendingPathComponent("AIME-ai.pdf")
var box = CGRect(x: 0, y: 0, width: width, height: height)
let pdf = CGContext(pdfURL as CFURL, mediaBox: &box, [kCGPDFContextCreator: "AIME scripts/gen-input-source-icon.swift"] as CFDictionary)!
pdf.beginPDFPage(nil)
pdf.addPath(icon)
pdf.setFillColor(.black)
pdf.fillPath(using: .evenOdd)
pdf.endPDFPage()
pdf.closePDF()

// SVG of the same outline, for review and the brand archive (y flipped to SVG space).
func svgPath(_ path: CGPath) -> String {
    var d = ""
    func p(_ point: CGPoint) -> String { String(format: "%.3f %.3f", point.x, height - point.y) }
    path.applyWithBlock { element in
        let e = element.pointee
        switch e.type {
        case .moveToPoint: d += "M\(p(e.points[0]))"
        case .addLineToPoint: d += "L\(p(e.points[0]))"
        case .addQuadCurveToPoint: d += "Q\(p(e.points[0])) \(p(e.points[1]))"
        case .addCurveToPoint: d += "C\(p(e.points[0])) \(p(e.points[1])) \(p(e.points[2]))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 22 16" width="22" height="16"><path fill="#000" fill-rule="evenodd" d="\(svgPath(icon))"/></svg>

"""
try svg.write(to: directory.appendingPathComponent("AIME-ai.svg"), atomically: true, encoding: .utf8)
try Data(contentsOf: pdfURL).write(to: root.appendingPathComponent("Apps/AIME/Resources/AIME.pdf"))
print("input source icon written: 艾 in Noto Sans SC wght \(Int(weight)), \(Int(width))×\(Int(height)) pt")
