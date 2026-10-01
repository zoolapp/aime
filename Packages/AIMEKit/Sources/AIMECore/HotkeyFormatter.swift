public import Foundation

/// Converts between key events and Rime's key notation (`Control+Shift+grave`), and
/// renders Rime notation for display (`⌃⇧\``). Pure functions so the settings key
/// recorder is testable without AppKit.
public enum HotkeyFormatter {
    /// US-layout virtual key codes → Rime key names for keys whose name is not their
    /// character (letters and digits are handled from the typed character).
    static let namedKeys: [UInt16: String] = [
        0x32: "grave", 0x1b: "minus", 0x18: "equal", 0x21: "bracketleft", 0x1e: "bracketright",
        0x2a: "backslash", 0x29: "semicolon", 0x27: "apostrophe", 0x2b: "comma", 0x2f: "period",
        0x2c: "slash", 0x31: "space", 0x30: "Tab", 0x24: "Return", 0x35: "Escape", 0x33: "BackSpace",
        0x75: "Delete", 0x74: "Page_Up", 0x79: "Page_Down", 0x73: "Home", 0x77: "End",
        0x7b: "Left", 0x7c: "Right", 0x7d: "Down", 0x7e: "Up", 0x39: "Caps_Lock",
        0x7a: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6d: "F10", 0x67: "F11", 0x6f: "F12",
    ]

    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let alt = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// Rime notation for a key press, or nil for keys that cannot be bound.
    public static func rimeName(keyCode: UInt16, character: String?, modifiers: Modifiers) -> String? {
        let key: String
        if let named = namedKeys[keyCode] {
            key = named
        } else if let character, let scalar = character.lowercased().unicodeScalars.first,
                  (0x61...0x7a).contains(scalar.value) || (0x30...0x39).contains(scalar.value) {
            key = String(Character(scalar))
        } else {
            return nil
        }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.alt) { parts.append("Alt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Super") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    static let displayKeys: [String: String] = [
        "grave": "`", "minus": "-", "equal": "=", "bracketleft": "[", "bracketright": "]", "backslash": "\\",
        "semicolon": ";", "apostrophe": "'", "comma": ",", "period": ".", "slash": "/", "space": "空格",
        "Tab": "⇥", "Return": "↩", "Escape": "⎋", "BackSpace": "⌫", "Delete": "⌦", "Page_Up": "⇞", "Page_Down": "⇟",
        "Home": "↖", "End": "↘", "Left": "←", "Right": "→", "Up": "↑", "Down": "↓", "Caps_Lock": "⇪",
        "numbersign": "#", "dollar": "$", "Shift_L": "左⇧", "Shift_R": "右⇧", "Control_L": "左⌃", "Control_R": "右⌃",
    ]

    /// `Control+Shift+grave` → `⌃⇧\``.
    public static func display(_ rime: String) -> String {
        guard !rime.isEmpty else { return "未设置" }
        var parts = rime.split(separator: "+").map(String.init)
        let key = parts.popLast() ?? ""
        let symbols = parts.map { part -> String in
            switch part {
            case "Control": "⌃"
            case "Alt": "⌥"
            case "Shift": "⇧"
            case "Super", "Command": "⌘"
            default: part
            }
        }.joined()
        let keyText = displayKeys[key] ?? (key.count == 1 ? key.uppercased() : key)
        return symbols + keyText
    }
}
