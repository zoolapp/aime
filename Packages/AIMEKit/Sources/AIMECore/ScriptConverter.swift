public import Foundation

/// 简繁转换 of a piece of text, on the Mac itself: the system's ICU transforms
/// (Hans-Hant / Hant-Hans). No network, no AI. Typing output uses librime's OpenCC
/// instead (see the `traditionalize` settings).
public enum ScriptConverter {
    public struct Variant: Sendable, Equatable {
        public var label: String
        public var text: String
    }

    public static func traditional(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }

    public static func simplified(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }

    /// The conversions that change something: 繁体 for Simplified text, 简体 for
    /// Traditional text, both for a mix. Empty when there is nothing to convert.
    public static func variants(for text: String) -> [Variant] {
        var result: [Variant] = []
        let toTraditional = traditional(text), toSimplified = simplified(text)
        let mostlySimplified = toTraditional != text
            && changedCount(text, toTraditional) >= changedCount(text, toSimplified)
        let candidates = mostlySimplified
            ? [Variant(label: "繁体", text: toTraditional), Variant(label: "简体", text: toSimplified)]
            : [Variant(label: "简体", text: toSimplified), Variant(label: "繁体", text: toTraditional)]
        for candidate in candidates where candidate.text != text && !result.contains(where: { $0.text == candidate.text }) {
            result.append(candidate)
        }
        return result
    }

    private static func changedCount(_ a: String, _ b: String) -> Int {
        zip(a, b).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }
}
