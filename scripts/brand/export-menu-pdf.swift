#!/usr/bin/env swift
// 16pt vector PDF candidate for the existing tsInputMethodIconFileKey.
import AppKit
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let directory = root.appendingPathComponent("assets/brand/aime/base-v1")
let raw = try Data(contentsOf: directory.appendingPathComponent("tokens.json"))
let tokens = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
let mark = tokens["mark"] as! [String: Any]
let menu = tokens["menu"] as! [String: Any]
let source = mark["path"] as! String
let expression = try NSRegularExpression(pattern: "[A-Za-z]|[-+]?[0-9]*\\.?[0-9]+")
let parts = expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { String(source[Range($0.range, in: source)!]) }
let path = CGMutablePath()
var i = 0; var point = CGPoint.zero
func number() -> CGFloat { defer { i += 1 }; return CGFloat(Double(parts[i])!) }
while i < parts.count {
    let command = parts[i]; i += 1
    switch command {
    case "M": point = CGPoint(x: number(), y: number()); path.move(to: point)
    case "L": point = CGPoint(x: number(), y: number()); path.addLine(to: point)
    case "H": point.x = number(); path.addLine(to: point)
    case "V": point.y = number(); path.addLine(to: point)
    case "C":
        let c1 = CGPoint(x: number(), y: number()), c2 = CGPoint(x: number(), y: number())
        point = CGPoint(x: number(), y: number()); path.addCurve(to: point, control1: c1, control2: c2)
    case "Z": path.closeSubpath()
    default: fatalError("Unsupported SVG command \(command)")
    }
}
var box = CGRect(x: 0, y: 0, width: 16, height: 16)
let output = directory.appendingPathComponent("menu/AIME-bookmark.pdf")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let context = CGContext(output as CFURL, mediaBox: &box, [kCGPDFContextTitle: "AIME bookmark menu icon", kCGPDFContextCreator: "AIME brand export"] as CFDictionary)!
context.beginPDFPage(nil)
context.translateBy(x: 0, y: 16); context.scaleBy(x: 1, y: -1)
context.translateBy(x: menu["markX"] as! CGFloat, y: menu["markY"] as! CGFloat)
let scale = (menu["markHeight"] as! CGFloat) / (mark["height"] as! CGFloat)
context.scaleBy(x: scale, y: scale)
context.addPath(path); context.setFillColor(NSColor.black.cgColor); context.fillPath()
context.endPDFPage(); context.closePDF()
print("Wrote 16×16pt vector PDF from the same canonical SVG path: \(output.path)")
