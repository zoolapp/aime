public import Foundation

/// `custom_phrase.txt`: a plain table of `text<TAB>code[<TAB>weight]` used by
/// `table_translator@custom_phrase`. Comment/header lines are preserved on save.
public struct CustomPhrases: Sendable, Equatable {
    public struct Phrase: Sendable, Hashable, Identifiable {
        public var id = UUID()
        public var text: String
        public var code: String
        public var weight: Int?

        public init(text: String, code: String, weight: Int? = nil) {
            self.text = text
            self.code = code
            self.weight = weight
        }

        public static func == (lhs: Phrase, rhs: Phrase) -> Bool {
            lhs.text == rhs.text && lhs.code == rhs.code && lhs.weight == rhs.weight
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(text); hasher.combine(code); hasher.combine(weight)
        }

        /// Anything librime can read back: non-empty text and code without tabs or line
        /// breaks. Codes may contain spaces (e.g. `img 1`), which librime accepts.
        public var isValid: Bool {
            !text.isEmpty && !code.trimmingCharacters(in: .whitespaces).isEmpty
                && !text.contains("\t") && !text.contains("\n") && !code.contains("\t") && !code.contains("\n")
        }
    }

    public var header: [String]
    public var phrases: [Phrase]
    /// Non-comment lines that could not be parsed. Kept verbatim so saving never loses
    /// anything the user wrote.
    public var unparsed: [String] = []

    public static let defaultHeader = [
        "# Rime table",
        "# coding: utf-8",
        "#@/db_name\tcustom_phrase.txt",
        "#@/db_type\ttabledb",
        "#",
        "# 自定义短语 — managed by AIME Settings; hand edits are kept.",
        "# 格式：词条<Tab>编码<Tab>权重（可选）",
        "#",
        "# 此行之后不能写注释",
    ]

    public init(header: [String] = CustomPhrases.defaultHeader, phrases: [Phrase] = []) {
        self.header = header
        self.phrases = phrases
    }

    public init(parsing text: String) {
        var header: [String] = []
        var phrases: [Phrase] = []
        var unparsed: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("#") {
                if phrases.isEmpty && unparsed.isEmpty { header.append(line) }
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let columns = line.components(separatedBy: "\t")
            guard columns.count >= 2, !columns[0].isEmpty, !columns[1].isEmpty,
                  columns.count == 2 || Int(columns[2].trimmingCharacters(in: .whitespaces)) != nil || columns[2].isEmpty
            else {
                unparsed.append(line)
                continue
            }
            let weight = columns.count > 2 ? Int(columns[2].trimmingCharacters(in: .whitespaces)) : nil
            phrases.append(Phrase(text: columns[0], code: columns[1], weight: weight))
        }
        self.init(header: header.isEmpty ? Self.defaultHeader : header, phrases: phrases)
        self.unparsed = unparsed
    }

    public static func load(from url: URL) -> CustomPhrases {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return CustomPhrases() }
        return CustomPhrases(parsing: text)
    }

    public var serialized: String {
        var lines = header
        for phrase in phrases where phrase.isValid {
            lines.append([phrase.text, phrase.code] .joined(separator: "\t") + (phrase.weight.map { "\t\($0)" } ?? ""))
        }
        lines.append(contentsOf: unparsed)
        return lines.joined(separator: "\n") + "\n"
    }

    public func save(to url: URL) throws {
        try serialized.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Adds a phrase unless the same text/code pair already exists. Returns whether added.
    @discardableResult
    public mutating func add(_ phrase: Phrase) -> Bool {
        guard phrase.isValid, !phrases.contains(where: { $0.text == phrase.text && $0.code == phrase.code }) else { return false }
        phrases.append(phrase)
        return true
    }
}
