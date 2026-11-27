import Foundation
import Testing
@testable import AIMECore

struct WritingJournalTests {
    let journal = WritingJournal(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("aime-journal-\(UUID().uuidString)"))

    @Test func recordsExportsAndClears() throws {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        journal.record(.init(time: time, app: "com.example.chat", kind: .typed, text: "今天先这样"))
        journal.record(.init(time: time.addingTimeInterval(5), app: "com.example.chat", kind: .action,
                             text: "你好", action: "翻译", result: "Hello"))
        let entries = journal.entries()
        #expect(entries.map(\.text) == ["今天先这样", "你好"])
        #expect(entries[1].action == "翻译" && entries[1].result == "Hello")

        let out = journal.directory.appendingPathComponent("export.out")
        try journal.export(to: out)
        let lines = try String(contentsOf: out, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2 && lines[0].contains("今天先这样"))

        journal.clear()
        #expect(journal.entries().isEmpty)
    }

    @Test func filesArePrivate() throws {
        journal.record(.init(app: "com.example.chat", kind: .typed, text: "私人内容"))
        journal.flush()
        let manager = FileManager.default
        let directory = try manager.attributesOfItem(atPath: journal.directory.path)[.posixPermissions] as? Int
        #expect(directory == 0o700)
        let file = try #require(try manager.contentsOfDirectory(at: journal.directory, includingPropertiesForKeys: nil).first)
        #expect(try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        journal.clear()
    }

    @Test func skipsPasswordManagersAndBlankText() {
        journal.record(.init(app: "com.1password.1password", kind: .typed, text: "secret"))
        journal.record(.init(app: "com.example.chat", kind: .typed, text: "  \n"))
        #expect(journal.entries().isEmpty)
    }

    @Test func offByDefault() throws {
        #expect(try JSONDecoder().decode(AIMEFeatures.self, from: Data("{}".utf8)).writingJournal == false)
    }
}
