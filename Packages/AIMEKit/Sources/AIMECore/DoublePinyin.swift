public import Foundation

/// Full pinyin syllables → double pinyin codes, so vocabulary shipped or subscribed in
/// full pinyin also works for double pinyin schemas (each syllable = two keys).
public enum DoublePinyin: String, Sendable, CaseIterable {
    /// 小鹤双拼 (double_pinyin_flypy)
    case flypy

    /// Schema ids that use this layout.
    public var schemaIDs: [String] {
        switch self { case .flypy: ["double_pinyin_flypy"] }
    }

    public static func layout(forSchema id: String) -> DoublePinyin? {
        allCases.first { $0.schemaIDs.contains(id) }
    }

    private var initials: [String: String] {
        switch self { case .flypy: ["zh": "v", "ch": "i", "sh": "u"] }
    }

    private var finals: [String: String] {
        switch self {
        case .flypy: [
            "iu": "q", "ei": "w", "uan": "r", "van": "r", "ue": "t", "ve": "t", "un": "y", "vn": "y", "uo": "o",
            "ie": "p", "ong": "s", "iong": "s", "ai": "d", "en": "f", "eng": "g", "ang": "h", "an": "j",
            "ing": "k", "uai": "k", "iang": "l", "uang": "l", "ou": "z", "ia": "x", "ua": "x", "ao": "c",
            "ui": "v", "v": "v", "in": "b", "iao": "n", "ian": "m",
        ]
        }
    }

    /// Two-key code for one syllable, or nil if it is not a valid syllable.
    public func code(forSyllable raw: String) -> String? {
        let syllable = raw.lowercased().replacingOccurrences(of: "ü", with: "v")
        guard !syllable.isEmpty, syllable.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        // Zero-initial syllables: a/o/e-led ones double the vowel or use the final's key.
        if let first = syllable.first, "aoe".contains(first) {
            switch syllable.count {
            case 1: return syllable + syllable
            case 2: return syllable
            default: return String(first) + (finals[syllable] ?? String(syllable.last!))
            }
        }
        for initial in ["zh", "ch", "sh"] where syllable.hasPrefix(initial) {
            let rest = String(syllable.dropFirst(2))
            guard let final = rest.count == 1 ? rest : finals[rest] else { return nil }
            return initials[initial]! + final
        }
        let initial = String(syllable.first!)
        let rest = String(syllable.dropFirst())
        // j/q/x/y + u is ü.
        let normalized = ("jqxy".contains(initial) && rest.hasPrefix("u")) ? "v" + rest.dropFirst() : rest
        if normalized.count == 1 { return initial + normalized }
        guard let final = finals[normalized] ?? finals[rest] else { return nil }
        return initial + final
    }

    /// Codes for a space-separated full pinyin string ("zhi neng ti" → "vingti").
    public func code(forPinyin pinyin: String) -> String? {
        let syllables = pinyin.split(separator: " ").map(String.init)
        guard !syllables.isEmpty else { return nil }
        var out = ""
        for syllable in syllables {
            guard let code = code(forSyllable: syllable) else { return nil }
            out += code
        }
        return out
    }
}
