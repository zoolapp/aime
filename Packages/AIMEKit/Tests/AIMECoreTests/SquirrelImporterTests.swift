import Foundation
import Testing
@testable import AIMECore

struct SquirrelImporterTests {
    let source: URL
    let paths: AIMEPaths

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aime-import-\(UUID().uuidString)")
        source = root.appendingPathComponent("Rime")
        paths = AIMEPaths(userDataDir: root.appendingPathComponent("AIME"))
        let fm = FileManager.default
        try fm.createDirectory(at: source.appendingPathComponent("build"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("lua"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("rime_ice.userdb"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("sync/abc-123"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent(".specstory"), withIntermediateDirectories: true)
        let files: [String: String] = [
            "default.custom.yaml": "# mine\npatch:\n  menu/page_size: 9\n",
            "rime_ice.custom.yaml": "patch:\n  speller/algebra: [\"derive/^l/n/\"]\n",
            "squirrel.custom.yaml": "patch:\n  style/color_scheme: ink\n  app_options:\n    com.apple.Terminal: {ascii_mode: true}\n",
            "squirrel.yaml": "preset_color_schemes:\n  ink:\n    name: Ink\n    back_color: 0x000000\n",
            "rime_ice.schema.yaml": "schema: {schema_id: rime_ice}\n",
            "custom_phrase.txt": "AIME\taime\t1\n",
            "installation.yaml": "installation_id: abc-123\n",
            "user.yaml": "var: {}\n",
            "build/default.yaml": "x: 1\n",
            "lua/date.lua": "-- lua\n",
            "rime_ice.userdb/LOCK": "",
            "sync/abc-123/rime_ice.userdb.txt": "# snapshot\n",
            ".specstory/history.md": "private\n",
            "README.md": "# readme\n",
            "go.work": "go 1.22\n",
        ]
        for (path, text) in files {
            try text.write(to: source.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
    }

    /// Snapshot of every file under the source with its modification date.
    private func fingerprint() throws -> [String: Date] {
        var result: [String: Date] = [:]
        let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.contentModificationDateKey])!
        for case let url as URL in enumerator {
            result[url.path] = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return result
    }

    @Test func plansSkipsAndLayers() throws {
        let plan = try SquirrelImporter(paths: paths, source: source).plan()
        #expect(plan.copies.sorted() == ["custom_phrase.txt", "lua", "rime_ice.schema.yaml"])
        #expect(plan.customs.map(\.1).contains(.frontend))
        #expect(plan.customs.map(\.1).contains(.schema("rime_ice")))
        let skipped = plan.actions.compactMap { if case let .skip(path, _) = $0 { path } else { nil } }
        #expect(Set(skipped) == ["build", "installation.yaml", "user.yaml", "squirrel.yaml", "rime_ice.userdb", ".specstory", "README.md", "go.work"])
    }

    @Test func importsWithoutTouchingSource() throws {
        let before = try fingerprint()
        let importer = SquirrelImporter(paths: paths, source: source)
        let report = try importer.execute(importer.plan())
        #expect(try fingerprint() == before)

        let layers = ConfigLayers(paths: paths)
        // Hand-written layers are byte-identical copies.
        #expect(try Data(contentsOf: layers.importedURL(.default)) == Data(contentsOf: source.appendingPathComponent("default.custom.yaml")))
        #expect(try Data(contentsOf: layers.importedURL(.frontend)) == Data(contentsOf: source.appendingPathComponent("squirrel.custom.yaml")))
        // Shims carry the composed imported patch.
        let shim = try String(contentsOf: layers.shimURL(.schema("rime_ice")), encoding: .utf8)
        #expect(shim.hasPrefix(ConfigLayers.shimMarker))
        #expect(shim.contains("derive/^l/n/"))
        // Snapshots staged for sync, live LevelDB and build output left behind.
        #expect(FileManager.default.fileExists(atPath: paths.userDataDir.appendingPathComponent("sync/abc-123/rime_ice.userdb.txt").path))
        #expect(!FileManager.default.fileExists(atPath: paths.userDataDir.appendingPathComponent("rime_ice.userdb").path))
        #expect(!FileManager.default.fileExists(atPath: paths.userDataDir.appendingPathComponent("build/default.yaml").path))
        #expect(!FileManager.default.fileExists(atPath: paths.userDataDir.appendingPathComponent("installation.yaml").path))
        // Referenced color scheme only defined in squirrel.yaml is carried over.
        #expect(report.colorSchemesCarriedOver == ["ink"])
        #expect(layers.generatedValue(.frontend, keypath: "preset_color_schemes/ink")?["name"] == "Ink")
        #expect(FileManager.default.fileExists(atPath: paths.aimeDir.appendingPathComponent("import-report.json").path))
    }

    @Test func reimportReplacesPreviousLayers() throws {
        let importer = SquirrelImporter(paths: paths, source: source)
        try importer.execute(importer.plan())
        try "patch:\n  menu/page_size: 7\n".write(to: source.appendingPathComponent("default.custom.yaml"), atomically: true, encoding: .utf8)
        try importer.execute(importer.plan())
        let text = try String(contentsOf: ConfigLayers(paths: paths).importedURL(.default), encoding: .utf8)
        #expect(text.contains("page_size: 7"))
    }
}

extension SquirrelImporterTests {
    @Test func refusesSameDirectoryAndWarnsWithoutSnapshots() throws {
        let selfImport = SquirrelImporter(paths: AIMEPaths(userDataDir: source), source: source)
        #expect(throws: SquirrelImporter.ImportError.self) { try selfImport.execute(selfImport.plan()) }

        try FileManager.default.removeItem(at: source.appendingPathComponent("sync/abc-123/rime_ice.userdb.txt"))
        let importer = SquirrelImporter(paths: paths, source: source)
        let report = try importer.execute(importer.plan())
        #expect(report.warnings.count == 1)
    }

    @Test func reimportBacksUpEditedImportedLayer() throws {
        let importer = SquirrelImporter(paths: paths, source: source)
        try importer.execute(importer.plan())
        try "# edited in AIME\npatch: {}\n".write(to: ConfigLayers(paths: paths).importedURL(.default), atomically: true, encoding: .utf8)
        try importer.execute(importer.plan())
        let backups = FileManager.default.enumerator(atPath: paths.aimeDir.appendingPathComponent("backup").path)?.allObjects as? [String] ?? []
        #expect(backups.contains { $0.hasSuffix("default.custom.yaml") })
    }
}

extension SquirrelImporterTests {
    @Test func reimportMergesPhraseTablesInsteadOfOverwriting() throws {
        try "# Rime table\n#@/db_type\ttabledb\n罗磊\tll\n".write(to: source.appendingPathComponent("custom_phrase_double.txt"), atomically: true, encoding: .utf8)
        let importer = SquirrelImporter(paths: paths, source: source)
        try importer.execute(importer.plan())
        let table = paths.userDataDir.appendingPathComponent("custom_phrase_double.txt")
        var edited = CustomPhrases.load(from: table)
        _ = edited.add(.init(text: "AIME 新增", code: "xz"))
        try edited.save(to: table)
        try importer.execute(importer.plan())
        let texts = CustomPhrases.load(from: table).phrases.map(\.text)
        #expect(texts.contains("罗磊") && texts.contains("AIME 新增"))
    }
}
