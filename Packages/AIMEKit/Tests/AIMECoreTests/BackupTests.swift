import Foundation
import Testing
@testable import AIMECore

struct BackupTests {
    let root: URL
    let paths: AIMEPaths
    let stats: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("aime-backup-test-\(UUID().uuidString)")
        paths = AIMEPaths(userDataDir: root.appendingPathComponent("Rime"), sharedDataDir: nil)
        stats = root.appendingPathComponent("Stats")
        let fm = FileManager.default
        for dir in ["aime/generated", "aime/imported", "aime/cache", "build", "cn_dicts", "lua", "rime_ice.userdb", "sync/dev-1", "my_dicts"] {
            try fm.createDirectory(at: paths.userDataDir.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: stats, withIntermediateDirectories: true)
        let files: [(String, String)] = [
            ("aime/generated/default.yaml", "patch:\n  menu/page_size: 9\n"),
            ("aime/imported/default.custom.yaml", "patch: {}\n"),
            ("aime/features.json", "{\"usageStats\":true}"),
            ("aime/snippets.json", "{\"categories\":[]}"),
            ("aime/cache/big.bin", "cache"),
            ("custom_phrase_double.txt", "艾么输入法\tam\n"),
            ("my.schema.yaml", "schema: {}\n"),
            ("my_dicts/words.dict.yaml", "---\n"),
            ("lua/helper.lua", "-- lua\n"),
            ("default.custom.yaml", "# composed by AIME\n"),
            ("build/default.yaml", "built"),
            ("cn_dicts/8105.dict.yaml", "shipped"),
            ("rime_ice.userdb/000001.ldb", "live"),
            ("sync/dev-1/rime_ice.userdb.txt", "你好\tni hao\tc=3\n"),
        ]
        for (path, text) in files { try text.write(to: paths.userDataDir.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        try "{\"智能体\":3}".write(to: stats.appendingPathComponent("2026-10-01.json"), atomically: true, encoding: .utf8)
    }

    var manager: BackupManager { BackupManager(paths: paths, statsDirectory: stats, safetyDirectory: root.appendingPathComponent("Backups")) }

    @Test func backsUpTheUsersOwnFilesOnly() throws {
        let included = Set(manager.plan(includeStats: false).map(\.0))
        #expect(included.isSuperset(of: ["rime/aime/generated/default.yaml", "rime/aime/imported/default.custom.yaml",
                                          "rime/aime/features.json", "rime/aime/snippets.json", "rime/custom_phrase_double.txt",
                                          "rime/my.schema.yaml", "rime/my_dicts/words.dict.yaml", "rime/lua/helper.lua",
                                          "rime/sync/dev-1/rime_ice.userdb.txt"]))
        // Rebuilt, shipped or live data stays out.
        #expect(!included.contains { $0.contains("cache") || $0.contains("build/") || $0.contains("cn_dicts") || $0.contains(".userdb/") })
        #expect(!included.contains("rime/default.custom.yaml"))
        #expect(!included.contains { $0.hasPrefix("stats/") })
        #expect(manager.plan(includeStats: true).contains { $0.0 == "stats/2026-10-01.json" })
    }

    @Test func roundTripRestoresAndKeepsASafetyCopy() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent(BackupManager.suggestedName())
        let manifest = try manager.create(at: archive, includeStats: true, appVersion: "0.1.0")
        #expect(manifest.version == 2)
        #expect(Set(manifest.directories ?? []) == Set(BackupManager.replacementDirectories))
        #expect(manifest.settingsCount >= 4 && manifest.phraseCount == 1 && manifest.frequencyCount == 1 && manifest.statsCount == 1)

        // Change things after the backup.
        let fm = FileManager.default
        try "patch:\n  menu/page_size: 5\n".write(to: paths.userDataDir.appendingPathComponent("aime/generated/default.yaml"), atomically: true, encoding: .utf8)
        try "stale".write(to: paths.userDataDir.appendingPathComponent("aime/generated/extra.yaml"), atomically: true, encoding: .utf8)
        try fm.removeItem(at: paths.userDataDir.appendingPathComponent("custom_phrase_double.txt"))

        let opened = try manager.open(archive)
        #expect(opened.manifest.appVersion == "0.1.0" && opened.manifest.includesStats)
        let safety = try manager.restore(opened)
        #expect(fm.fileExists(atPath: safety.path))
        let restored = try String(contentsOf: paths.userDataDir.appendingPathComponent("aime/generated/default.yaml"), encoding: .utf8)
        #expect(restored.contains("page_size: 9"))
        #expect(!fm.fileExists(atPath: paths.userDataDir.appendingPathComponent("aime/generated/extra.yaml").path)) // layer replaced whole
        #expect(fm.fileExists(atPath: paths.userDataDir.appendingPathComponent("custom_phrase_double.txt").path))
        // The safety copy holds the state from just before the restore.
        let undo = try manager.open(safety)
        #expect(undo.manifest.files["rime/aime/generated/extra.yaml"] != nil)
        manager.close(undo)
    }

    @Test func refusesDamagedOrForeignArchives() throws {
        let archive = root.appendingPathComponent("a.\(BackupManager.fileExtension)")
        try manager.create(at: archive, includeStats: false)
        // Tamper with one file inside the archive.
        let unpacked = root.appendingPathComponent("unpacked")
        try BackupManager.ditto(["-x", "-k", archive.path, unpacked.path])
        try "patch: {evil: true}\n".write(to: unpacked.appendingPathComponent("AIME Backup/rime/aime/generated/default.yaml"), atomically: true, encoding: .utf8)
        let tampered = root.appendingPathComponent("b.\(BackupManager.fileExtension)")
        try BackupManager.ditto(["-c", "-k", "--keepParent", unpacked.appendingPathComponent("AIME Backup").path, tampered.path])
        #expect(throws: BackupManager.BackupError.self) { try manager.open(tampered) }
        // A zip that is not a backup.
        let other = root.appendingPathComponent("c.zip")
        try BackupManager.ditto(["-c", "-k", "--keepParent", stats.path, other.path])
        #expect(throws: BackupManager.BackupError.self) { try manager.open(other) }
    }

    @Test(arguments: ["my_dicts", "aime/generated", "aime", "stats/nested"])
    func refusesEscapingParentsWithoutTouchingAnyDestination(parent: String) throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let isStats = parent.hasPrefix("stats/")
        let directory = isStats ? stats.appendingPathComponent("nested") : paths.userDataDir.appendingPathComponent(parent)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = parent == "aime" ? "features.json" : "sentinel.lua"
        try "archive-value".write(to: directory.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("safe.aimebackup")
        try manager.create(at: archive, includeStats: true)

        // The sibling deliberately shares the root's string prefix.
        let outside = root.appendingPathComponent("Rime-outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent(filename)
        try "outside-original".write(to: sentinel, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: sentinel.path)
        let before = try fm.attributesOfItem(atPath: sentinel.path)[.modificationDate] as? Date
        try fm.removeItem(at: directory)
        try fm.createSymbolicLink(at: directory, withDestinationURL: outside)
        let untouched = paths.userDataDir.appendingPathComponent("custom_phrase_double.txt")
        try "current-value".write(to: untouched, atomically: true, encoding: .utf8)

        let opened = try manager.open(archive)
        #expect(throws: BackupManager.BackupError.self) { try manager.restore(opened) }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "outside-original")
        #expect(try fm.attributesOfItem(atPath: sentinel.path)[.modificationDate] as? Date == before)
        #expect(try String(contentsOf: untouched, encoding: .utf8) == "current-value")
        #expect(!fm.fileExists(atPath: manager.safetyDirectory.path))
    }

    @Test func refusesSymlinkMembersEvenOutsideTheManifest() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("original.aimebackup")
        try manager.create(at: archive, includeStats: false)
        let unpacked = root.appendingPathComponent("unpacked")
        try BackupManager.ditto(["-x", "-k", archive.path, unpacked.path])
        let content = unpacked.appendingPathComponent("AIME Backup")
        let link = content.appendingPathComponent("unlisted-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: paths.generatedDir)
        let malicious = root.appendingPathComponent("symlink.aimebackup")
        try BackupManager.ditto(["-c", "-k", "--keepParent", content.path, malicious.path])
        #expect(throws: BackupManager.BackupError.self) { try manager.open(malicious) }
    }

    @Test(arguments: ["rime/my.userdb/000001.ldb", "rime/my.userdb", "rime/build/default.yaml",
                      "rime/aime/.lock", "rime/my_dicts/LOCK", "rime/lua/session.lock", "stats/build/cache",
                      "rime/../outside.lua", "rime//bad.lua", "rime/aime/cache/secret", "rime/installation.yaml"])
    func refusesProtectedOrInvalidManifestPaths(relative: String) throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try makeArchive(files: [relative: "untrusted"])
        #expect(throws: BackupManager.BackupError.self) { try manager.open(archive) }
    }

    @Test func enforcesExpandedMemberAndByteLimits() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent("limits")
        let fm = FileManager.default
        try fm.createDirectory(at: tree.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let file = tree.appendingPathComponent("payload")
        try Data([0, 1, 2]).write(to: file)
        try BackupManager.validateTree(tree, maximumMembers: 2, maximumBytes: 3)
        #expect(throws: BackupManager.BackupError.self) { try BackupManager.validateTree(tree, maximumMembers: 1) }
        #expect(throws: BackupManager.BackupError.self) { try BackupManager.validateTree(tree, maximumBytes: 2) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        // A sparse file tests the production byte limit without allocating 512 MB.
        try handle.truncate(atOffset: BackupManager.maximumExpandedBytes + 1)
        #expect(throws: BackupManager.BackupError.self) { try BackupManager.validateTree(tree) }
    }

    @Test func refusesUnknownFormatVersion() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try makeArchive(files: [:], version: 99)
        #expect(throws: BackupManager.BackupError.self) { try manager.open(archive) }
    }

    @Test(arguments: [false, true])
    func emptyVersionTwoLayersClearLaterOverrides(directoriesExist: Bool) throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let layers = [paths.generatedDir, paths.importedDir, paths.aimeDir.appendingPathComponent("subscriptions")]
        for directory in layers {
            if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
            if directoriesExist { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        }
        let archive = root.appendingPathComponent("empty.aimebackup")
        let manifest = try manager.create(at: archive, includeStats: false)
        #expect(manifest.version == 2)
        for directory in layers {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try "patch:\n  menu/page_size: 9\n".write(to: directory.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
        }
        #expect(ConfigLayers(paths: paths).generatedValue(.default, keypath: "menu/page_size") == 9)
        try manager.restore(manager.open(archive))
        #expect(ConfigLayers(paths: paths).generatedValue(.default, keypath: "menu/page_size") == nil)
        for directory in layers { #expect(try fm.contentsOfDirectory(atPath: directory.path).isEmpty) }
    }

    @Test func restoresIntoAFreshWorkspace() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("fresh.aimebackup")
        let manifest = try manager.create(at: archive, includeStats: true)
        let fresh = BackupManager(paths: AIMEPaths(userDataDir: root.appendingPathComponent("fresh/Rime")),
                                  statsDirectory: root.appendingPathComponent("fresh/Stats"),
                                  safetyDirectory: root.appendingPathComponent("fresh/Backups"))
        try fresh.restore(fresh.open(archive))
        var restored: [String: String] = [:]
        for (relative, file) in fresh.plan(includeStats: true) { restored[relative] = try PackageManager.sha256(of: file) }
        #expect(restored == manifest.files)
    }

    @Test(arguments: [false, true])
    func restoresVersionOneWithoutChangingItsMissingLayerSemantics(hasGenerated: Bool) throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let files = hasGenerated ? ["rime/aime/generated/default.yaml": "patch:\n  menu/page_size: 5\n"] : [:]
        let archive = try makeArchive(files: files)
        let opened = try manager.open(archive)
        #expect(opened.manifest.version == 1)
        #expect(opened.manifest.directories == nil)
        // Verify the fixture really has no v2 directories field on disk.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: opened.content.appendingPathComponent("manifest.json"))) as? [String: Any]
        #expect(json?["directories"] == nil)
        let extra = paths.generatedDir.appendingPathComponent("extra.yaml")
        try "later".write(to: extra, atomically: true, encoding: .utf8)
        try manager.restore(opened)
        #expect(ConfigLayers(paths: paths).generatedValue(.default, keypath: "menu/page_size") == (hasGenerated ? 5 : 9))
        #expect(fm.fileExists(atPath: extra.path) == !hasGenerated)
        #expect(try String(contentsOf: paths.importedDir.appendingPathComponent("default.custom.yaml"), encoding: .utf8) == "patch: {}\n")
    }

    @Test(arguments: [1, 2])
    func rollsBackEveryChangeWhenALaterWriteFails(version: Int) throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        // Hidden content and empty directories are deliberately absent from plan(),
        // but must still survive a failed whole-layer replacement.
        try "hidden-before".write(to: paths.generatedDir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: paths.generatedDir.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let blocker = stats.appendingPathComponent("zz-blocker")
        try "parent-is-a-file".write(to: blocker, atomically: true, encoding: .utf8)
        let before = try snapshot()
        let archive = try makeArchive(files: [
            "rime/aime/generated/default.yaml": "patch:\n  menu/page_size: 5\n",
            "rime/aime/imported/new.yaml": "replacement",
            "rime/aime/subscriptions/new.txt": "new-subscription",
            "rime/custom_phrase_double.txt": "replacement-phrase",
            "rime/new_folder/nested/new.lua": "new-file",
            "stats/2026-10-01.json": "replacement-stats",
            "stats/new/nested/new.json": "new-stats",
            "stats/zz-blocker/failure.json": "cannot-write-through-a-file",
        ], version: version)
        let opened = try manager.open(archive)
        #expect(throws: (any Error).self) { try manager.restore(opened) }
        #expect(try snapshot() == before)
        let safety = try #require(try fm.contentsOfDirectory(at: manager.safetyDirectory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == BackupManager.fileExtension })
        let saved = try manager.open(safety)
        #expect(saved.manifest.files["rime/aime/generated/default.yaml"] != nil)
        manager.close(saved)
        #expect(try fm.contentsOfDirectory(atPath: manager.safetyDirectory.path).allSatisfy { !$0.hasPrefix(".restore-") })
    }

    @Test func emptyLayerStillRejectsAnEscapingDestination() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.removeItem(at: paths.generatedDir)
        let archive = root.appendingPathComponent("empty.aimebackup")
        try manager.create(at: archive, includeStats: false)
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("default.yaml")
        try "outside-before".write(to: sentinel, atomically: true, encoding: .utf8)
        let before = try fm.attributesOfItem(atPath: sentinel.path)[.modificationDate] as? Date
        try fm.createSymbolicLink(at: paths.generatedDir, withDestinationURL: outside)
        #expect(throws: BackupManager.BackupError.self) { try manager.restore(manager.open(archive)) }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "outside-before")
        #expect(try fm.attributesOfItem(atPath: sentinel.path)[.modificationDate] as? Date == before)
    }

    private struct SnapshotItem: Equatable {
        let data: Data?
        let modified: Date?
    }

    private func snapshot() throws -> [String: SnapshotItem] {
        let fm = FileManager.default
        var result: [String: SnapshotItem] = [:]
        for (prefix, directory) in [("rime", paths.userDataDir), ("stats", stats)] {
            let enumerator = try #require(fm.enumerator(at: directory, includingPropertiesForKeys: nil))
            for case let file as URL in enumerator {
                let attributes = try fm.attributesOfItem(atPath: file.path)
                let regular = attributes[.type] as? FileAttributeType == .typeRegular
                let relative = prefix + "/" + file.path.dropFirst(directory.path.count + 1)
                result[relative] = SnapshotItem(data: regular ? try Data(contentsOf: file) : nil,
                                                modified: regular ? attributes[.modificationDate] as? Date : nil)
            }
        }
        return result
    }

    private func makeArchive(files: [String: String], version: Int = 1) throws -> URL {
        let content = root.appendingPathComponent(UUID().uuidString).appendingPathComponent("AIME Backup")
        let fm = FileManager.default
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
        var digests: [String: String] = [:]
        for (relative, text) in files {
            let file = content.appendingPathComponent(relative)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            digests[relative] = try PackageManager.sha256(of: file)
        }
        let directories = version == 2 ? BackupManager.replacementDirectories : nil
        for directory in directories ?? [] {
            try fm.createDirectory(at: content.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let manifest = BackupManager.Manifest(format: BackupManager.format, version: version, created: Date(),
                                              includesStats: files.keys.contains { $0.hasPrefix("stats/") }, files: digests, directories: directories)
        try BackupManager.encoder.encode(manifest).write(to: content.appendingPathComponent("manifest.json"))
        let archive = root.appendingPathComponent("\(UUID().uuidString).aimebackup")
        try BackupManager.ditto(["-c", "-k", "--keepParent", content.path, archive.path])
        return archive
    }
}
