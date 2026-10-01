import Foundation
import Testing
@testable import AIMECore

struct PackageManagerTests {
    let root: URL
    let paths: AIMEPaths

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("aime-pkg-test-\(UUID().uuidString)")
        paths = AIMEPaths(userDataDir: root.appendingPathComponent("user"))
        try FileManager.default.createDirectory(at: paths.userDataDir, withIntermediateDirectories: true)
    }

    /// Zips `files` under a wrapping folder, like a GitHub release asset.
    func makeArchive(_ name: String, files: [String: String]) throws -> URL {
        let folder = root.appendingPathComponent("src-\(name)/pack")
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let zip = root.appendingPathComponent("\(name).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        try process.run()
        process.waitUntilExit()
        return zip
    }

    func package(_ id: String, archive: URL, tag: String = "1.0") throws -> DictionaryPackage {
        DictionaryPackage(
            id: id, title: id, summary: "", homepage: "", license: "MIT", kind: .schema, schemas: ["demo"], requires: [],
            source: .init(type: "raw", tag: tag, url: archive.absoluteString, filename: archive.lastPathComponent),
            sha256: try PackageManager.sha256(of: archive), size: nil
        )
    }

    func manager(_ packages: [DictionaryPackage]) -> PackageManager {
        PackageManager(paths: paths, registry: DictionaryRegistry(version: 1, packages: packages)) { url in
            try Data(contentsOf: url)
        }
    }

    @Test func installsVerifiedArchiveAndWritesManifest() async throws {
        let zip = try makeArchive("v1", files: [
            "demo.schema.yaml": "schema: {schema_id: demo}\n",
            "cn_dicts/base.dict.yaml": "---\nname: base\n...\n",
            "demo.custom.yaml": "patch: {evil: true}\n",
            "installation.yaml": "installation_id: nope\n",
        ])
        let pkg = try package("demo", archive: zip)
        let record = try await manager([pkg]).install("demo")
        #expect(Set(record.files.keys) == ["demo.schema.yaml", "cn_dicts/base.dict.yaml"])
        #expect(FileManager.default.fileExists(atPath: paths.userDataDir.appendingPathComponent("cn_dicts/base.dict.yaml").path))
        #expect(!FileManager.default.fileExists(atPath: paths.userDataDir.appendingPathComponent("demo.custom.yaml").path))
        #expect(!FileManager.default.fileExists(atPath: paths.userDataDir.appendingPathComponent("installation.yaml").path))
        #expect(manager([pkg]).installed("demo")?.version == "1.0")
    }

    @Test func rejectsTamperedArchive() async throws {
        let zip = try makeArchive("v1", files: ["demo.schema.yaml": "ok\n"])
        var pkg = try package("demo", archive: zip)
        pkg.sha256 = String(repeating: "0", count: 64)
        await #expect(throws: PackageError.self) { try await manager([pkg]).install("demo") }
        #expect(!FileManager.default.fileExists(atPath: paths.userDataDir.appendingPathComponent("demo.schema.yaml").path))
        #expect(manager([pkg]).installed("demo") == nil)
    }

    @Test func backsUpUserFilesItOverwrites() async throws {
        let mine = paths.userDataDir.appendingPathComponent("demo.schema.yaml")
        try "# my edits\n".write(to: mine, atomically: true, encoding: .utf8)
        let zip = try makeArchive("v1", files: ["demo.schema.yaml": "schema: {schema_id: demo}\n"])
        let record = try await manager([try package("demo", archive: zip)]).install("demo")
        let backup = try #require(record.backupDir)
        #expect(try String(contentsOfFile: backup + "/demo.schema.yaml", encoding: .utf8) == "# my edits\n")
    }

    @Test func upgradesAndUninstallsCleanly() async throws {
        let v1 = try makeArchive("v1", files: ["demo.schema.yaml": "v1\n", "old.dict.yaml": "old\n"])
        _ = try await manager([try package("demo", archive: v1)]).install("demo")
        let v2 = try makeArchive("v2", files: ["demo.schema.yaml": "v2\n"])
        let upgraded = try await manager([try package("demo", archive: v2, tag: "2.0")]).install("demo")
        #expect(upgraded.backupDir == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.userDataDir.appendingPathComponent("old.dict.yaml").path))

        // A file the user edited after install survives uninstall.
        let schema = paths.userDataDir.appendingPathComponent("demo.schema.yaml")
        try "edited\n".write(to: schema, atomically: true, encoding: .utf8)
        let result = try manager([]).uninstall("demo")
        #expect(result.kept == ["demo.schema.yaml"])
        #expect(manager([]).installed("demo") == nil)
    }

    @Test func bundledRegistryIsPinned() {
        let registry = DictionaryRegistry.bundled
        #expect(registry.packages.count >= 5)
        for package in registry.packages {
            #expect(package.sha256.count == 64, "\(package.id) sha256")
            #expect(package.source.downloadURL?.scheme == "https", "\(package.id) url")
        }
    }
}

extension PackageManagerTests {
    @Test func skipsControlDirSymlinksAndDatabases() async throws {
        let zip = try makeArchive("evil", files: [
            "aime/generated/default.yaml": "patch: {evil: true}\n",
            "rime_ice.userdb/CURRENT": "x\n",
            "sync/abc/rime_ice.userdb.txt": "x\n",
            "ok.dict.yaml": "ok\n",
        ])
        let record = try await manager([try package("evil", archive: zip)]).install("evil")
        #expect(Array(record.files.keys) == ["ok.dict.yaml"])
    }

    @Test func sharedFilesSurviveUninstallOfOneOwner() async throws {
        let a = try makeArchive("a", files: ["shared.dict.yaml": "same\n", "a.txt": "a\n"])
        let b = try makeArchive("b", files: ["shared.dict.yaml": "same\n"])
        let packages = [try package("a", archive: a), try package("b", archive: b)]
        _ = try await manager(packages).install("a")
        _ = try await manager(packages).install("b")
        let result = try manager(packages).uninstall("a")
        #expect(result.kept.contains("shared.dict.yaml"))
        #expect(FileManager.default.fileExists(atPath: paths.userDataDir.appendingPathComponent("shared.dict.yaml").path))
    }
}
