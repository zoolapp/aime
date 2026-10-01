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
        let archive = root.appendingPathComponent(BackupManager.suggestedName())
        let manifest = try manager.create(at: archive, includeStats: true, appVersion: "0.1.0")
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
}
