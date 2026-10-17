@testable import AIMECore
import Foundation
import Testing

struct VocabularyParserTests {
    @Test func keepsHighestDuplicateWeightAndFirstOccurrenceOrder() {
        let parsed = VocabularyParser.parse("新词\txin ci\t20\n旧词\tjiu ci\t60\n新词\txin ci\t90\n新词\txin ci\t10\n")
        #expect(parsed == [
            VocabularyEntry(text: "新词", pinyin: "xin ci", weight: 90),
            VocabularyEntry(text: "旧词", pinyin: "jiu ci", weight: 60)
        ])
    }

    @Test func normalizesCodesWithoutMergingDifferentReadings() {
        let parsed = VocabularyParser.parse("银行\t YIN   HANG \t20\n银行\tyin\u{00a0}hang\t90\n银行\tyin xing\t30\n")
        #expect(parsed == [
            VocabularyEntry(text: "银行", pinyin: "yin hang", weight: 90),
            VocabularyEntry(text: "银行", pinyin: "yin xing", weight: 30)
        ])
    }

    @Test(arguments: ["[weight, text, code, stem]", "\n  - weight\n  - text\n  - code\n  - stem"])
    func honorsDeclaredColumnOrder(columns: String) {
        let parsed = VocabularyParser.parse("---\nname: demo\ncolumns: \(columns)\n...\n90\t银行\tyin hang\tignored\n")
        #expect(parsed == [VocabularyEntry(text: "银行", pinyin: "yin hang", weight: 90)])
    }

    @Test func preservesDeclaredNumericCodes() {
        let parsed = VocabularyParser.parse("---\nname: demo\ncolumns: [text, code, weight]\n...\n数字\t123\t80\n")
        #expect(parsed == [VocabularyEntry(text: "数字", pinyin: "123", weight: 80)])
        #expect(VocabularyParser.parse("---\nname: demo\ncolumns: [text, code]\n...\n数字\t123\n")
            == [VocabularyEntry(text: "数字", pinyin: "123")])
    }

    @Test func preservesWeightsInUndeclaredTwoColumnTables() {
        #expect(VocabularyParser.parse("新词\t 100 \n银行\tyin hang\n") == [
            VocabularyEntry(text: "新词", pinyin: "xin ci", weight: 100),
            VocabularyEntry(text: "银行", pinyin: "yin hang")
        ])
    }

    @Test func keepsEmptyFieldsInTheirDeclaredColumns() {
        let parsed = VocabularyParser.parse("---\nname: demo\ncolumns: [code, text, weight]\n...\n\t新词\t90\nxin ci\t\t70\n")
        #expect(parsed == [VocabularyEntry(text: "新词", pinyin: "xin ci", weight: 90)])
        #expect(VocabularyParser.parse("\txin ci\t90\n").isEmpty)
    }

    @Test func fillsMissingCodeWithoutGuessingWeightFromOtherColumns() {
        let parsed = VocabularyParser.parse("---\nname: demo\ncolumns: [text, stem, weight]\n...\n新词\t123\t90\n旧词\t456\n")
        #expect(parsed == [
            VocabularyEntry(text: "新词", pinyin: "xin ci", weight: 90),
            VocabularyEntry(text: "旧词", pinyin: "jiu ci")
        ])
    }

    @Test func preservesLegacyTablesAndPlainLists() {
        #expect(VocabularyParser.parse("智能体\tzhi neng ti\tai_term\t95\n")
            == [VocabularyEntry(text: "智能体", pinyin: "zhi neng ti", weight: 95)])
        #expect(VocabularyParser.parse("---\nname: demo\n...\n银行\tyin hang\t90\n")
            == [VocabularyEntry(text: "银行", pinyin: "yin hang", weight: 90)])
        #expect(VocabularyParser.parse("# comment\n\n新词\nClaude\n") == [
            VocabularyEntry(text: "新词", pinyin: "xin ci"),
            VocabularyEntry(text: "Claude", pinyin: "claude")
        ])
    }

    @Test func stripsLeadingByteOrderMark() {
        #expect(VocabularyParser.parse("\u{feff}新词\n") == [VocabularyEntry(text: "新词", pinyin: "xin ci")])
        let parsed = VocabularyParser.parse("\u{feff}# comment\n---\nname: demo\ncolumns: [text, weight, code]\n...\n银行\t90\tyin hang\n")
        #expect(parsed == [VocabularyEntry(text: "银行", pinyin: "yin hang", weight: 90)])
    }

    @Test(arguments: ["[text, code, code]", "[weight, code]", "[text, 1]", "[]", "text", "[text, code"])
    func rejectsInvalidColumns(columns: String) {
        #expect(VocabularyParser.parse("---\nname: demo\ncolumns: \(columns)\n...\n银行\tyin hang\t90\n").isEmpty)
    }

    @Test func rejectsAmbiguousOrIncompleteHeaders() {
        let duplicate = "---\nname: demo\ncolumns: [text, code]\ncolumns: [code, text]\n...\n银行\tyin hang\n"
        #expect(VocabularyParser.parse(duplicate).isEmpty)
        #expect(VocabularyParser.parse("# comment\n---\nname: demo\ncolumns: [text, code]\n银行\tyin hang\n").isEmpty)
        let oversized = "---\nname: demo\ndescription: " + String(repeating: "x", count: 64 * 1024) + "\n...\n银行\tyin hang\n"
        #expect(VocabularyParser.parse(oversized).isEmpty)
    }

    @Test func rebuildsExistingTablesWithTheCorrectedParser() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("aime-parser-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let paths = AIMEPaths(userDataDir: root)
        let manager = SubscriptionManager(paths: paths)
        let item = VocabularySubscription(id: "sample", name: "Sample", url: URL(string: "https://example.invalid/dict.yaml")!, addedAt: Date())
        try manager.save([item])
        let cache = manager.cacheURL(item.id)
        try fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = Data("\u{feff}---\nname: demo\ncolumns: [text, weight, code]\n...\n银行\t20\tyin hang\n银行\t90\tyin hang\n".utf8)
        try content.write(to: cache)
        let modified = try cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try "schema_list:\n  - schema: rime_ice\n".write(to: root.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
        try manager.rebuild(schemas: ["rime_ice"])
        let table = root.appendingPathComponent("aime_online.txt")
        try "银行\tyinxing\t50\n".write(to: table, atomically: true, encoding: .utf8)
        let signature = manager.tableSignature(schemas: ["rime_ice"], items: [item])
        let oldSignature = "v2|" + signature.split(separator: "|", maxSplits: 1)[1]
        try oldSignature.write(to: paths.aimeDir.appendingPathComponent("subscriptions/.signature"), atomically: true, encoding: .utf8)

        #expect(try manager.ensureTables())
        let rows = try String(contentsOf: table, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }
        #expect(rows == ["银行\tyinhang\t90"])
        #expect(try Data(contentsOf: cache) == content)
        #expect(try cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        #expect(try manager.ensureTables() == false)
    }
}
