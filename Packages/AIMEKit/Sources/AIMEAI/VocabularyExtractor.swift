public import AIMECore
public import Foundation

/// Finds names, brands and jargon in text the user pastes, so they can be added to
/// custom phrases. The model only selects terms; input codes are computed locally.
public struct VocabularyExtractor: Sendable {
    public struct Term: Sendable, Hashable, Identifiable {
        public var id: String { text + "\t" + code }
        public var text: String
        public var code: String
        public var note: String
    }

    public let provider: any AIProvider

    public init(provider: any AIProvider) { self.provider = provider }

    static let instructions = """
    你帮助输入法用户从一段文字中找出值得加入个人词库的词：人名、品牌、产品、专业术语、网络新词、固定搭配。
    忽略常见词。严格只输出 JSON 数组，不要其他文字：[{"text":"词条","note":"简短类别"}]，最多 40 项。
    """

    public func extract(from text: String, excluding existing: Set<String> = []) async throws -> [Term] {
        let reply = try await provider.complete(instructions: Self.instructions, prompt: String(text.prefix(8000)))
        return try parse(reply, excluding: existing)
    }

    func parse(_ reply: String, excluding existing: Set<String>) throws -> [Term] {
        struct Item: Decodable { let text: String; let note: String? }
        guard let data = JSONExtractor.firstJSON(in: reply), let items = try? JSONDecoder().decode([Item].self, from: data)
        else { throw AIError.badResponse(String(reply.prefix(120))) }
        var seen = Set<String>()
        return items.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 24, !existing.contains(text), seen.insert(text).inserted,
                  let code = Self.inputCode(for: text) else { return nil }
            return Term(text: text, code: code, note: item.note ?? "")
        }
    }

    /// Full-pinyin code for Chinese text (via ICU transliteration), lowercase letters
    /// and digits for Latin text. Mixed text keeps both, e.g. "小米SU7" → "xiaomisu7".
    public static func inputCode(for text: String) -> String? {
        guard let toned = text.applyingTransform(.mandarinToLatin, reverse: false) else { return nil }
        // ü must become v before diacritics are stripped (which would turn it into u).
        let marked = toned.lowercased().replacingOccurrences(of: #"[üǖǘǚǜ]"#, with: "v", options: .regularExpression)
        guard let latin = marked.applyingTransform(.stripDiacritics, reverse: false) else { return nil }
        let code = latin.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return code.isEmpty ? nil : code
    }
}
