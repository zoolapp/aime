import Foundation
import Testing
import RimeKit
@testable import AIMECore

@MainActor
@Suite(.serialized)
struct ImportedFrequencyTests {
    @Test func externalSnapshotMergesIntoDestinationUserDictionary() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("aime-frequency-\(UUID().uuidString)")
        let shared = root.appendingPathComponent("shared")
        let source = root.appendingPathComponent("source")
        let external = root.appendingPathComponent("external")
        let destination = root.appendingPathComponent("destination")
        let engine = RimeEngine.shared
        defer { engine.finalize(); try? fm.removeItem(at: root) }
        for dir in [shared, source, external, destination] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try "schema_list: [{schema: frequency_test}]\n".write(to: shared.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
        try """
        schema: {schema_id: frequency_test, name: 测试, version: '1'}
        engine:
          processors: [speller, selector, express_editor]
          segmentors: [abc_segmentor, fallback_segmentor]
          translators: [script_translator]
        speller: {alphabet: abcdefghijklmnopqrstuvwxyz, delimiter: " '"}
        translator: {dictionary: frequency_test, enable_user_dict: true}
        """.write(to: shared.appendingPathComponent("frequency_test.schema.yaml"), atomically: true, encoding: .utf8)
        try "---\nname: frequency_test\nversion: '1'\nsort: by_weight\n...\n你好\tni hao\t100\n".write(to: shared.appendingPathComponent("frequency_test.dict.yaml"), atomically: true, encoding: .utf8)
        try ConfigValue.map([.init("installation_id", "source-test"), .init("sync_dir", .string(external.path))]).yamlString()
            .write(to: source.appendingPathComponent("installation.yaml"), atomically: true, encoding: .utf8)
        engine.initialize(RimeTraits(sharedDataDir: shared, userDataDir: source, minLogLevel: 2))
        engine.deployAndWait()
        do {
            let session = try engine.createSession()
            #expect(session.selectSchema("frequency_test"))
            #expect(session.simulate(keySequence: "nihao"))
            let index = try #require(session.context().candidates.firstIndex { $0.text == "你好" })
            #expect(session.selectCandidate(onCurrentPage: index))
            #expect(session.consumeCommit() == "你好")
        }
        #expect(engine.syncUserData())
        engine.joinMaintenance()
        engine.finalize()
        let snapshot = external.appendingPathComponent("source-test/frequency_test.userdb.txt")
        let original = try Data(contentsOf: snapshot)
        #expect(String(decoding: original, as: UTF8.self).contains("你好"))
        let paths = AIMEPaths(userDataDir: destination, sharedDataDir: shared)
        let importer = SquirrelImporter(paths: paths, source: source)
        let report = try importer.execute(importer.plan())
        #expect(report.snapshots == ["source-test/frequency_test.userdb.txt"])
        #expect(report.warnings.isEmpty)
        engine.initialize(RimeTraits(sharedDataDir: shared, userDataDir: destination, minLogLevel: 2))
        engine.deployAndWait()
        let invalid = root.appendingPathComponent("invalid.userdb.txt")
        try "invalid snapshot".write(to: invalid, atomically: true, encoding: .utf8)
        #expect(!engine.restoreUserDictionary(from: invalid))
        #expect(engine.restoreUserDictionary(from: destination.appendingPathComponent("sync/source-test/frequency_test.userdb.txt")))
        #expect(engine.syncUserData())
        engine.joinMaintenance()
        engine.finalize()
        let installation = try ConfigValue.load(contentsOf: destination.appendingPathComponent("installation.yaml"))
        let id = try #require(installation["installation_id"]?.stringValue)
        #expect(id != "source-test")
        let merged = try String(contentsOf: destination.appendingPathComponent("sync/\(id)/frequency_test.userdb.txt"), encoding: .utf8)
        #expect(merged.contains("你好"))
        #expect(merged.contains("c=1"))
        #expect(try Data(contentsOf: snapshot) == original)
    }
}
