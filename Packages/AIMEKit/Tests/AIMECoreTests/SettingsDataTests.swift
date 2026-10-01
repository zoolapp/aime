import Foundation
import Testing
@testable import AIMECore

struct SettingsDataTests {
    let paths: AIMEPaths

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aime-data-\(UUID().uuidString)")
        paths = AIMEPaths(userDataDir: root.appendingPathComponent("user"), sharedDataDir: root.appendingPathComponent("shared"))
        try FileManager.default.createDirectory(at: paths.stagingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.sharedDataDir!, withIntermediateDirectories: true)
    }

    @Test func customPhrasesRoundTripKeepsHeader() throws {
        let source = "# Rime table\n#@/db_name\tcustom_phrase.txt\n#\n# 此行之后不能写注释\n示例\tsl\t100\nhello@example.com\tmail\n"
        var phrases = CustomPhrases(parsing: source)
        #expect(phrases.phrases.count == 2)
        #expect(phrases.phrases[0].weight == 100)
        let added = phrases.add(.init(text: "AIME", code: "aime"))
        let duplicate = phrases.add(.init(text: "AIME", code: "aime"))
        let invalid = phrases.add(.init(text: "bad", code: "has\ttab"))
        #expect(added && !duplicate && !invalid)
        let output = phrases.serialized
        #expect(output.hasPrefix("# Rime table\n#@/db_name\tcustom_phrase.txt"))
        #expect(output.contains("AIME\taime\n"))
        #expect(CustomPhrases(parsing: output) == phrases)
    }

    @Test func discoversSchemasFromBothDirs() throws {
        try "schema:\n  schema_id: demo\n  name: 演示\n  author:\n    - 甲\nengine: {}\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("demo.schema.yaml"), atomically: true, encoding: .utf8)
        try "# comment\nschema:\n  schema_id: mine\n  name: \"我的\"\n  description: |\n    自用方案\n".write(
            to: paths.userDataDir.appendingPathComponent("mine.schema.yaml"), atomically: true, encoding: .utf8)
        let schemas = SchemaDiscovery.available(paths: paths)
        #expect(schemas.map(\.id) == ["demo", "mine"])
        #expect(schemas[0].author == "甲")
        #expect(schemas[1].fromUserDir && schemas[1].summary == "自用方案")
    }

    @Test func editsSchemaListAndAppOptions() throws {
        try "app_options:\n  com.apple.Terminal:\n    ascii_mode: true\n".write(to: paths.builtConfig("aime"), atomically: true, encoding: .utf8)
        let store = SettingsStore(paths: paths)
        try store.setEnabledSchemas(["rime_ice", "double_pinyin_flypy"])
        #expect(store.pendingSchemas() == ["rime_ice", "double_pinyin_flypy"])

        #expect(store.appOptions().map(\.bundleID) == ["com.apple.Terminal"])
        try store.setAppOption(.init(bundleID: "com.microsoft.VSCode", initialMode: .english, vimMode: true))
        #expect(store.appOptions().last?.vimMode == true)
        try store.setAppOption(.init(bundleID: "com.tencent.xinWeChat", initialMode: .chinese))
        #expect(store.appOptions().last?.initialMode == .chinese)
        try store.removeAppOption("com.tencent.xinWeChat")
        try store.removeAppOption("com.apple.Terminal")
        #expect(store.appOptions().map(\.bundleID) == ["com.microsoft.VSCode"])
    }

    @Test func setsSyncDir() throws {
        try "installation_id: abc\n".write(to: paths.userDataDir.appendingPathComponent("installation.yaml"), atomically: true, encoding: .utf8)
        let store = SettingsStore(paths: paths)
        try store.setSyncDir("/Users/me/iCloud/RimeSync")
        #expect(store.syncDir == "/Users/me/iCloud/RimeSync")
        #expect(store.installationInfo()["installation_id"] == "abc")
        try store.setSyncDir(nil)
        #expect(store.syncDir == nil)
    }
}

extension SettingsDataTests {
    /// Real-world tables mix formats; saving must never drop a line the user wrote.
    @Test func phraseTablesRoundTripLosslessly() throws {
        let source = """
        # Rime table
        #@/db_name\tcustom_phrase.txt
        ![]()\timg 1
        :site \tust 1
        someone@example.com\tumg\t1
        无编码的行
        \t只有编码
        奇怪\tcode\tnot-a-number
        """
        let parsed = CustomPhrases(parsing: source)
        #expect(parsed.phrases.map(\.code) == ["img 1", "ust 1", "umg"])
        #expect(parsed.phrases[1].text == ":site ")
        #expect(parsed.unparsed.count == 3)
        let output = parsed.serialized
        for line in source.split(separator: "\n") where !line.hasPrefix("#") {
            #expect(output.contains(String(line)), "lost line: \(line)")
        }
        #expect(CustomPhrases(parsing: output) == parsed)
    }
}
