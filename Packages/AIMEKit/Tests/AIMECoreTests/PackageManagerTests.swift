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

    func model(archive: URL) throws -> DictionaryPackage {
        DictionaryPackage(
            id: "wanxiang-lts-zh-hans", title: "万象整句模型", summary: "", homepage: "https://github.com/amzxyz/RIME-LMDG",
            license: "CC-BY-4.0", kind: .model, schemas: [], requires: ["octagram"],
            source: .init(type: "github-release-asset", repo: "amzxyz/RIME-LMDG", tag: "LTS",
                          asset: "wanxiang-lts-zh-hans.gram", filename: "wanxiang-lts-zh-hans.gram", assetID: 607935157),
            sha256: try PackageManager.sha256(of: archive),
            size: try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            licenseURL: "https://creativecommons.org/licenses/by/4.0/", attribution: "amzxyz and RIME-LMDG contributors"
        )
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

private actor PackageFileDownloadStub {
    let temporary: URL
    let status: Int
    private(set) var calls = 0
    private(set) var request: URLRequest?

    init(temporary: URL, status: Int = 200) {
        self.temporary = temporary
        self.status = status
    }

    func download(_ request: URLRequest) throws -> (URL, URLResponse) {
        calls += 1
        self.request = request
        let response = try #require(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil))
        return (temporary, response)
    }
}

extension PackageManagerTests {
    @Test func immutableModelAssetIsPinnedAndUsesBinaryAcceptHeader() throws {
        let pkg = try #require(DictionaryRegistry.bundled.package("wanxiang-lts-zh-hans"))
        #expect(pkg.kind == .model && pkg.schemas.isEmpty)
        #expect(pkg.source.assetID == 607935157)
        #expect(pkg.source.tag == "LTS" && pkg.version == "asset-607935157")
        var nextAsset = pkg
        nextAsset.source.assetID = 607935158
        #expect(nextAsset.version == "asset-607935158" && nextAsset.version != pkg.version)
        #expect(pkg.size == 404661292)
        #expect(pkg.sha256 == "e3f958d2557a2c027543e874c802dcce9022b9b6fe1673d97c0bd1ef30592264")
        #expect(pkg.source.downloadURL?.absoluteString == "https://api.github.com/repos/amzxyz/RIME-LMDG/releases/assets/607935157")
        #expect(pkg.source.downloadRequest?.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
        #expect(pkg.source.filename == "wanxiang-lts-zh-hans.gram")
        #expect(pkg.license == "CC-BY-4.0" && pkg.attribution?.isEmpty == false)

        let oldSource = try JSONDecoder().decode(DictionaryPackage.Source.self, from: Data(#"{"type":"raw","url":"https://example.com/essay.txt","filename":"essay.txt"}"#.utf8))
        #expect(oldSource.assetID == nil)
        #expect(oldSource.downloadRequest?.value(forHTTPHeaderField: "Accept") == nil)
    }

    @Test func fileDownloadVerifiesCachesAndInstallsOnlyModelWithAttribution() async throws {
        let temporary = root.appendingPathComponent("download.tmp")
        // More than one SHA chunk exercises the bounded-memory verification path.
        try Data(repeating: 0x47, count: (1 << 20) + 17).write(to: temporary)
        let pkg = try model(archive: temporary)
        let stub = PackageFileDownloadStub(temporary: temporary)
        let manager = PackageManager(paths: paths, registry: DictionaryRegistry(version: 1, packages: [pkg]),
                                     download: { request in try await stub.download(request) })
        let cached = try await manager.download(pkg)
        #expect(cached.lastPathComponent == "\(pkg.sha256.prefix(16))-wanxiang-lts-zh-hans.gram")
        #expect(try PackageManager.sha256(of: cached) == pkg.sha256)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(try await manager.download(pkg) == cached)
        #expect(await stub.calls == 1)
        #expect(await stub.request?.value(forHTTPHeaderField: "Accept") == "application/octet-stream")

        let record = try manager.install(pkg, archive: cached)
        #expect(Set(record.files.keys) == ["wanxiang-lts-zh-hans.gram"])
        #expect(record.sourceURL == pkg.source.downloadURL?.absoluteString)
        #expect(record.license == pkg.license && record.licenseURL == pkg.licenseURL)
        #expect(record.attribution == pkg.attribution)
        #expect(manager.installed(pkg.id)?.attribution == pkg.attribution)
        let result = try manager.uninstall(pkg.id)
        #expect(result.removed == ["wanxiang-lts-zh-hans.gram"] && result.kept.isEmpty)
    }

    @Test func invalidFileDownloadIsRemovedWithoutInstalling() async throws {
        let temporary = root.appendingPathComponent("download.tmp")
        try Data("model fixture".utf8).write(to: temporary)
        var pkg = try model(archive: temporary)
        pkg.sha256 = String(repeating: "0", count: 64)
        let stub = PackageFileDownloadStub(temporary: temporary)
        let manager = PackageManager(paths: paths, registry: DictionaryRegistry(version: 1, packages: [pkg]),
                                     download: { request in try await stub.download(request) })
        await #expect(throws: PackageError.self) { try await manager.install(pkg.id) }
        #expect(await stub.calls == 1)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(manager.installed(pkg.id) == nil)
        #expect((try FileManager.default.contentsOfDirectory(atPath: paths.cacheDir.path)).isEmpty)
    }

    @Test func failedHttpFileDownloadIsRemovedWithoutRetry() async throws {
        let temporary = root.appendingPathComponent("download.tmp")
        try Data("model fixture".utf8).write(to: temporary)
        let pkg = try model(archive: temporary)
        let stub = PackageFileDownloadStub(temporary: temporary, status: 403)
        let manager = PackageManager(paths: paths, registry: DictionaryRegistry(version: 1, packages: [pkg]),
                                     download: { request in try await stub.download(request) })
        await #expect(throws: PackageError.self) { try await manager.download(pkg) }
        #expect(await stub.calls == 1)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }

    @Test func rejectsModelSizeMismatchAndSchemaArchive() throws {
        let payload = root.appendingPathComponent("model.gram")
        try Data("model fixture".utf8).write(to: payload)
        var wrongSize = try model(archive: payload)
        wrongSize.size = 1000
        #expect(throws: PackageError.self) { try manager([]).install(wrongSize, archive: payload) }

        let zip = try makeArchive("schema-model", files: ["demo.schema.yaml": "schema: {schema_id: demo}\n"])
        #expect(throws: PackageError.self) { try manager([]).install(try model(archive: zip), archive: zip) }
        #expect(!FileManager.default.fileExists(atPath: paths.userDataDir.appendingPathComponent("demo.schema.yaml").path))
    }

    @Test func legacyDataFetchAssignmentStillWorks() async throws {
        let payload = root.appendingPathComponent("model.gram")
        let data = Data("model fixture".utf8)
        try data.write(to: payload)
        let pkg = try model(archive: payload)
        var manager = PackageManager(paths: paths)
        manager.fetch = { _ in data }
        let cached = try await manager.download(pkg)
        #expect(try Data(contentsOf: cached) == data)
    }

    @Test func oldInstalledManifestStillDecodes() throws {
        let manager = manager([])
        try FileManager.default.createDirectory(at: paths.packagesDir, withIntermediateDirectories: true)
        let json = #"{"id":"legacy","version":"1","sha256":"old","installedAt":"2026-01-01T00:00:00Z","files":{}}"#
        try Data(json.utf8).write(to: manager.manifestURL("legacy"))
        let record = try #require(manager.installed("legacy"))
        #expect(record.sourceURL == nil && record.license == nil && record.licenseURL == nil && record.attribution == nil)
    }
}
