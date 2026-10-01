#!/usr/bin/env swift
// End-to-end typing test: selects the AIME input source, types into a fresh TextEdit
// document through real key events, reads back the text, then restores the previous
// input source.   swift scripts/e2e-typing.swift [keys] [expected]
import Carbon
import Foundation

let keys = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "nihao "
let expected = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "你好"

func sources(_ id: String) -> [TISInputSource] {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
}

let previous = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
guard let aime = sources("app.zool.inputmethod.aime.hans").first else {
    print("FAIL: AIME input source not registered"); exit(1)
}
TISEnableInputSource(aime)

func osa(_ script: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

_ = osa(#"tell application "TextEdit" to activate"#)
_ = osa(#"tell application "TextEdit" to make new document"#)
Thread.sleep(forTimeInterval: 1.2)
TISSelectInputSource(aime)
// Give the system time to launch the input method process on first selection.
Thread.sleep(forTimeInterval: 3.0)

// Key events via System Events (needs Accessibility permission for osascript);
// they go through the active input method like physical keystrokes.
// One osascript call for the whole sequence: separate calls would make IMK commit the
// composition between keystrokes.
_ = osa("tell application \"System Events\" to keystroke \"\(keys)\"")
Thread.sleep(forTimeInterval: 1.0)
let text = osa(#"tell application "TextEdit" to get text of front document"#)
TISSelectInputSource(previous)
_ = osa(#"tell application "TextEdit" to close front document saving no"#)
print("typed: \(keys.debugDescription) → document: \(text.debugDescription)")
if text.contains(expected) { print("PASS"); exit(0) } else { print("FAIL: expected \(expected)"); exit(1) }
