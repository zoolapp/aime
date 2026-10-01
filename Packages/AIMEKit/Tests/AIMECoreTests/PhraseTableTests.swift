import Foundation
import Testing
@testable import AIMECore

struct PhraseTableTests {
    let paths: AIMEPaths

    init() throws {
        paths = AIMEPaths(userDataDir: FileManager.default.temporaryDirectory.appendingPathComponent("aime-phrases-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: paths.stagingDir, withIntermediateDirectories: true)
        try "schema_list:\n  - schema: rime_ice\n  - schema: double_pinyin_flypy\n".write(to: paths.builtConfig("default"), atomically: true, encoding: .utf8)
        try "custom_phrase:\n  user_dict: custom_phrase\n".write(to: paths.builtConfig("rime_ice.schema"), atomically: true, encoding: .utf8)
        try "custom_phrase:\n  user_dict: custom_phrase_double\n".write(to: paths.builtConfig("double_pinyin_flypy.schema"), atomically: true, encoding: .utf8)
    }

    @Test func discoversTablesPerSchema() {
        let tables = SettingsStore(paths: paths).phraseTables()
        #expect(tables.map(\.name) == ["custom_phrase", "custom_phrase_double"])
        #expect(tables[1].schemas == ["double_pinyin_flypy"])
    }

    @Test func importMergesWithoutDuplicatesAndBacksUp() throws {
        let store = SettingsStore(paths: paths)
        let table = store.phraseTables()[1]
        try "# Rime table\n罗磊\tll\n".write(to: store.phraseTableURL(table), atomically: true, encoding: .utf8)
        let source = paths.userDataDir.appendingPathComponent("incoming.txt")
        try "# Rime table\n罗磊\tll\nAIME\taime\t9\nbad\thas\ttab\textra\n".write(to: source, atomically: true, encoding: .utf8)
        let result = try store.importPhrases(from: source, into: table)
        #expect(result == PhraseMergeResult(added: 1, skipped: 1))
        #expect(CustomPhrases.load(from: store.phraseTableURL(table)).phrases.map(\.text) == ["罗磊", "AIME"])
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: paths.aimeDir.appendingPathComponent("backup").path)) ?? []
        #expect(backups.contains { $0.hasSuffix("custom_phrase_double.txt") })
    }
}
