import Foundation

/// Rewrites text the user explicitly selected and asked to polish (⌃⌥P in the input
/// method). Only that selection is sent — never what is being composed, never learned
/// frequencies. Returns up to three variants for the candidate window.
public struct TextPolisher: Sendable {
    public struct Variant: Sendable, Equatable {
        public var label: String
        public var text: String
        public init(label: String, text: String) {
            self.label = label
            self.text = text
        }
    }

    public static let maxLength = 2000
    public let provider: any AIProvider

    public init(provider: any AIProvider) { self.provider = provider }

    static let instructions = """
    你是中文写作助手。用户会给你一段他自己选中的文字，请给出三个改写版本，保持原意和语言（中文仍用中文，英文仍用英文），
    不要添加原文没有的事实，不要解释。严格只输出 JSON：
    {"polished":"更通顺自然、修正错别字和标点","formal":"更正式书面","concise":"更简洁"}
    """

    public func polish(_ text: String) async throws -> [Variant] {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return [] }
        guard input.utf16.count <= Self.maxLength else { throw AIError.unavailable("选中的文字超过 \(Self.maxLength) 字") }
        let reply = try await provider.complete(instructions: Self.instructions, prompt: input)
        return try Self.parse(reply, original: input)
    }

    static func parse(_ reply: String, original: String) throws -> [Variant] {
        guard let data = JSONExtractor.firstJSON(in: reply),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AIError.badResponse(String(reply.prefix(120))) }
        var seen: Set<String> = [original]
        return [("polished", "润色"), ("formal", "正式"), ("concise", "简洁")].compactMap { key, label in
            guard let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, seen.insert(value).inserted else { return nil }
            return Variant(label: label, text: value)
        }
    }
}

/// What the quick menu can do with a piece of text the user just typed or selected:
/// polish, translate, or a prompt of their own. Only that text is sent, and only when
/// the user picks the action.
public enum TextAction: Sendable, Equatable {
    case polish
    /// Chinese → English, anything else → Simplified Chinese.
    case translate
    case custom(name: String, prompt: String)

    public var title: String {
        switch self {
        case .polish: "润色"
        case .translate: "翻译"
        case let .custom(name, _): name
        }
    }
}

public struct TextActionRunner: Sendable {
    public let provider: any AIProvider

    public init(provider: any AIProvider) { self.provider = provider }

    static let translateInstructions = """
    你是翻译助手。判断用户文字的主要语言：如果是中文，译成自然地道的英文；否则译成简体中文。
    不要解释，不要添加原文没有的内容。严格只输出 JSON：{"translation":"最自然的译文","alternative":"另一种说法"}
    """

    /// Runs `action` on `text` and returns the variants to offer (at least one).
    public func run(_ action: TextAction, on text: String) async throws -> [TextPolisher.Variant] {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return [] }
        guard input.utf16.count <= TextPolisher.maxLength else {
            throw AIError.unavailable("文字超过 \(TextPolisher.maxLength) 字")
        }
        switch action {
        case .polish:
            return try await TextPolisher(provider: provider).polish(input)
        case .translate:
            let reply = try await provider.complete(instructions: Self.translateInstructions, prompt: input)
            return try Self.parseTranslation(reply, original: input)
        case let .custom(name, prompt):
            let instructions = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n只输出处理后的文字本身，不要解释，不要加引号或代码块。"
            let reply = try await provider.complete(instructions: instructions, prompt: input)
            let cleaned = Self.unwrap(reply)
            guard !cleaned.isEmpty, cleaned != input else { return [] }
            return [.init(label: name, text: cleaned)]
        }
    }

    static func parseTranslation(_ reply: String, original: String) throws -> [TextPolisher.Variant] {
        guard let data = JSONExtractor.firstJSON(in: reply),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Models sometimes answer with the bare translation.
            let bare = unwrap(reply)
            guard !bare.isEmpty, bare != original else { throw AIError.badResponse(String(reply.prefix(120))) }
            return [.init(label: "译文", text: bare)]
        }
        var seen: Set<String> = [original]
        return [("translation", "译文"), ("alternative", "另一种")].compactMap { key, label in
            guard let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, seen.insert(value).inserted else { return nil }
            return .init(label: label, text: value)
        }
    }

    /// Strips code fences and wrapping quotes from a plain-text reply.
    static func unwrap(_ reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (open, close) in [("\"", "\""), ("“", "”"), ("「", "」")] where text.count >= 2 && text.hasPrefix(open) && text.hasSuffix(close) {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }
}
