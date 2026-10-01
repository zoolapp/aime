public import Foundation

/// A phrase table (`table_translator@custom_phrase` user_dict) and the schemas using it.
public struct PhraseTable: Sendable, Hashable, Identifiable {
    /// File name without extension, e.g. `custom_phrase_double`.
    public let name: String
    public let schemas: [String]
    public var id: String { name }
    public var fileName: String { "\(name).txt" }

    public init(name: String, schemas: [String]) {
        self.name = name
        self.schemas = schemas
    }
}

public struct PhraseMergeResult: Sendable, Equatable {
    public var added: Int
    public var skipped: Int
}

extension CustomPhrases {
    /// Adds every valid phrase from `other` that is not already present.
    @discardableResult
    public mutating func merge(_ other: CustomPhrases) -> PhraseMergeResult {
        var result = PhraseMergeResult(added: 0, skipped: 0)
        var existing = Set(phrases.map { "\($0.text)\t\($0.code)" })
        for phrase in other.phrases {
            let key = "\(phrase.text)\t\(phrase.code)"
            if phrase.isValid, existing.insert(key).inserted {
                phrases.append(Phrase(text: phrase.text, code: phrase.code, weight: phrase.weight))
                result.added += 1
            } else {
                result.skipped += 1
            }
        }
        return result
    }

    /// True for Rime text tables (custom_phrase-style files).
    public static func looksLikeTable(_ url: URL) -> Bool {
        guard url.pathExtension == "txt", let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 512)) ?? Data(), as: UTF8.self)
        return head.contains("# Rime table") || head.contains("db_type\ttabledb")
    }
}

extension SettingsStore {
    /// Phrase tables used by the enabled schemas (from each schema's
    /// `custom_phrase/user_dict`), plus any table file already in the user directory.
    public func phraseTables() -> [PhraseTable] {
        var bySchema: [String: [String]] = [:]
        for schema in pendingSchemas() {
            let name = built(.schema(schema))?.value(at: "custom_phrase/user_dict")?.stringValue ?? "custom_phrase"
            bySchema[name, default: []].append(schema)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: paths.userDataDir.path)) ?? []
        for file in files where file.hasPrefix("custom_phrase") && file.hasSuffix(".txt") {
            let name = String(file.dropLast(4))
            if bySchema[name] == nil { bySchema[name] = [] }
        }
        if bySchema.isEmpty { bySchema["custom_phrase"] = [] }
        return bySchema.keys.sorted().map { PhraseTable(name: $0, schemas: bySchema[$0]!) }
    }

    public func phraseTableURL(_ table: PhraseTable) -> URL {
        paths.userDataDir.appendingPathComponent(table.fileName)
    }

    /// Merges phrases from `source` (a table file) into `table`, backing the table up first.
    @discardableResult
    public func importPhrases(from source: URL, into table: PhraseTable) throws -> PhraseMergeResult {
        let destination = phraseTableURL(table)
        var current = CustomPhrases.load(from: destination)
        let result = current.merge(CustomPhrases.load(from: source))
        guard result.added > 0 else { return result }
        if FileManager.default.fileExists(atPath: destination.path) {
            let backup = paths.aimeDir.appendingPathComponent("backup/phrases-\(Int(Date().timeIntervalSince1970))-\(table.fileName)")
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: destination, to: backup)
        }
        try current.save(to: destination)
        return result
    }
}
