import Foundation
import Testing
@testable import AIMECore

struct SubscriptionTests {
    let root: URL
    let paths: AIMEPaths

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("aime-sub-\(UUID().uuidString)")
        paths = AIMEPaths(userDataDir: root.appendingPathComponent("user"), sharedDataDir: root.appendingPathComponent("shared"))
        try FileManager.default.createDirectory(at: paths.sharedDataDir!.appendingPathComponent("aime"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.userDataDir, withIntermediateDirectories: true)
        try "智能体\tzhi neng ti\tai_term\t95\nDeepSeek\tdeepseek\tai_company\t95\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("aime/aime_tech.tsv"), atomically: true, encoding: .utf8)
    }

    @Test func parsesDictYamlTablesAndWordLists() {
        let yaml = "---\nname: demo\nversion: \"1\"\n...\n具身智能\tju shen zhi neng\t80\n"
        #expect(VocabularyParser.parse(yaml).first == VocabularyEntry(text: "具身智能", pinyin: "ju shen zhi neng", weight: 80))
        let words = VocabularyParser.parse("# comment\n氛围编程\nClaude\n")
        #expect(words.map(\.pinyin) == ["fen wei bian cheng", "claude"])
        #expect(VocabularyParser.parse("绿色\n").first?.pinyin == "lv se")
    }

    @Test func normalizesGithubBlobURLs() {
        #expect(SubscriptionManager.normalize("https://github.com/foru17/words/blob/main/ai.txt")?.absoluteString
                == "https://raw.githubusercontent.com/foru17/words/main/ai.txt")
        #expect(SubscriptionManager.normalize("ftp://x") == nil)
    }

    @Test func addUpdateReportsNewWordsAndHonorsInterval() async throws {
        let source = root.appendingPathComponent("feed.txt")
        try "氛围编程\n智能体\n".write(to: source, atomically: true, encoding: .utf8)
        let manager = SubscriptionManager(paths: paths)
        let added = try await manager.add(url: source.absoluteString, name: "我的词库")
        #expect(added.entryCount == 2 && added.lastError == nil)

        try "氛围编程\n智能体\n具身智能\n".write(to: source, atomically: true, encoding: .utf8)
        // Automatic update right after is throttled.
        let throttled = try await manager.update(id: added.id)
        #expect(throttled?.entryCount == 2)
        let forced = try await manager.update(id: added.id, force: true)
        #expect(forced?.entryCount == 3 && forced?.newEntries == 1 && forced?.recentWords == ["具身智能"])
    }

    @Test func rebuildWritesLayoutTablesAndMountsSchemas() async throws {
        let source = root.appendingPathComponent("feed.txt")
        try "氛围编程\n".write(to: source, atomically: true, encoding: .utf8)
        let manager = SubscriptionManager(paths: paths)
        try await manager.add(url: source.absoluteString, name: nil)
        let count = try manager.rebuild(schemas: ["rime_ice", "double_pinyin_flypy"])
        #expect(count == 3)
        let full = try String(contentsOf: paths.userDataDir.appendingPathComponent("aime_online.txt"), encoding: .utf8)
        let flypy = try String(contentsOf: paths.userDataDir.appendingPathComponent("aime_online_flypy.txt"), encoding: .utf8)
        #expect(full.contains("智能体\tzhinengti") && full.contains("DeepSeek\tdeepseek"))
        #expect(flypy.contains("智能体\tvingti") && flypy.contains("氛围编程\tffwwbmig"))
        let layers = ConfigLayers(paths: paths)
        #expect(layers.generatedValue(.schema("double_pinyin_flypy"), keypath: "aime_online")?["user_dict"] == "aime_online_flypy")
        #expect(layers.generatedValue(.schema("rime_ice"), keypath: "engine/translators/+") == ["table_translator@aime_online"])
    }

    @Test func ensureTablesDedupesAndRebuildsOnlyWhenInputsChange() async throws {
        try "schema_list:\n  - schema: rime_ice\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
        let manager = SubscriptionManager(paths: paths)
        #expect(try manager.ensureTables())
        #expect(try manager.ensureTables() == false)

        let source = root.appendingPathComponent("feed.txt")
        try "智能体\n氛围编程\n".write(to: source, atomically: true, encoding: .utf8)
        try await manager.add(url: source.absoluteString, name: nil)
        #expect(try manager.ensureTables())
        let full = try String(contentsOf: paths.userDataDir.appendingPathComponent("aime_online.txt"), encoding: .utf8)
        #expect(full.components(separatedBy: "智能体\tzhinengti").count == 2) // one row, bundled weight kept
        #expect(full.contains("智能体\tzhinengti\t95"))
        // librime skips a table translator whose user dict is disabled.
        #expect(ConfigLayers(paths: paths).generatedValue(.schema("rime_ice"), keypath: "aime_online")?["enable_user_dict"] == nil)
    }

    @Test func mountsOnlyPinyinSchemasAndRemountsDeletedLayers() throws {
        try "schema_list:\n  - schema: rime_ice\n  - schema: double_pinyin_mspy\n  - schema: t9\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
        let manager = SubscriptionManager(paths: paths)
        #expect(try manager.ensureTables())
        let layers = ConfigLayers(paths: paths)
        #expect(layers.generatedValue(.schema("rime_ice"), keypath: "aime_online") != nil)
        #expect(layers.generatedValue(.schema("double_pinyin_mspy"), keypath: "aime_online") == nil)
        #expect(layers.generatedValue(.schema("t9"), keypath: "aime_online") == nil)
        // The user deletes the generated layer: the next deploy mounts again.
        try FileManager.default.removeItem(at: paths.aimeDir.appendingPathComponent("generated/rime_ice.yaml"))
        #expect(try manager.ensureTables())
        #expect(ConfigLayers(paths: paths).generatedValue(.schema("rime_ice"), keypath: "aime_online") != nil)
    }

    @Test func shippedCatalogDecodes() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appendingPathComponent("SharedSupport/aime/vocabulary-catalog.json"))
        let catalog = try JSONDecoder().decode(VocabularyCatalog.self, from: data)
        #expect(catalog.feeds.count >= 3)
        // Official feeds come from the website, each pinned to a version and SHA-256.
        #expect(catalog.feeds.allSatisfy { $0.url.host == "aime.zool.app" && $0.url.path.hasPrefix("/resources/") })
        #expect(catalog.feeds.allSatisfy { $0.sha256?.count == 64 && $0.version != nil && $0.entries == 160 })
        #expect(catalog.homepage?.absoluteString == "https://aime.zool.app/dictionaries/")
        #expect(VocabularyCatalog.remoteURL.absoluteString == "https://aime.zool.app/api/vocabulary.json")
    }
}

extension SubscriptionTests {
    @Test func intervalsDecideAutomaticUpdates() async throws {
        let source = root.appendingPathComponent("feed.txt")
        try "氛围编程\n".write(to: source, atomically: true, encoding: .utf8)
        let manager = SubscriptionManager(paths: paths)
        let added = try await manager.add(url: source.absoluteString, name: nil)
        #expect(added.updateInterval == .daily)
        try "氛围编程\n智能体\n".write(to: source, atomically: true, encoding: .utf8)
        let start = added.lastChecked!
        // Daily: not after 6 hours, yes after 25.
        #expect(try await manager.update(id: added.id, now: start.addingTimeInterval(6 * 3600))?.entryCount == 1)
        #expect(try await manager.update(id: added.id, now: start.addingTimeInterval(25 * 3600))?.entryCount == 2)
        // Weekly and manual.
        try manager.setInterval(id: added.id, .weekly)
        try "氛围编程\n智能体\n具身智能\n".write(to: source, atomically: true, encoding: .utf8)
        #expect(try await manager.update(id: added.id, now: start.addingTimeInterval(3 * 24 * 3600))?.entryCount == 2)
        try manager.setInterval(id: added.id, .manual)
        #expect(try await manager.update(id: added.id, now: start.addingTimeInterval(30 * 24 * 3600))?.entryCount == 2)
        #expect(try await manager.update(id: added.id, force: true)?.entryCount == 3)   // 立即检查 still works
    }

    @Test func catalogFeedsAreVerifiedAndFollowNewVersions() async throws {
        let v1 = root.appendingPathComponent("v1.txt"), v2 = root.appendingPathComponent("v2.txt")
        try "氛围编程\n".write(to: v1, atomically: true, encoding: .utf8)
        try "氛围编程\n具身智能\n".write(to: v2, atomically: true, encoding: .utf8)
        func feed(_ url: URL, sha: String) -> VocabularyCatalog.Feed {
            VocabularyCatalog.Feed(id: "ai-terms", name: "AI 术语", description: "", category: "ai", entries: nil, url: url,
                                   version: nil, updated: nil, sha256: sha, size: nil)
        }
        let manager = SubscriptionManager(paths: paths)
        let sha1 = PackageManager.sha256(of: try Data(contentsOf: v1))
        // A wrong checksum is refused.
        let bad = try await manager.add(url: v1.absoluteString, name: nil, feed: feed(v1, sha: String(repeating: "0", count: 64)))
        #expect(bad.lastError?.contains("SHA-256") == true && bad.entryCount == 0)
        try manager.remove(id: bad.id)
        let good = try await manager.add(url: v1.absoluteString, name: nil, feed: feed(v1, sha: sha1))
        #expect(good.entryCount == 1 && good.lastError == nil)
        // The catalog publishes v2: the subscription follows it on the next automatic check.
        let catalog = VocabularyCatalog(version: 1, name: "AIME", homepage: nil, updated: nil,
                                        feeds: [feed(v2, sha: PackageManager.sha256(of: try Data(contentsOf: v2)))])
        _ = await manager.updateDue(now: good.lastChecked!.addingTimeInterval(25 * 3600), catalog: { catalog })
        let after = manager.subscriptions().first { $0.id == good.id }
        #expect(after?.url == v2 && after?.entryCount == 2 && after?.lastError == nil)
    }
}

extension SubscriptionTests {
    @Test func olderSubscriptionsAreAdoptedByFileName() async throws {
        let old = root.appendingPathComponent("github/ai-terms-dev-tools.txt")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "氛围编程\n".write(to: old, atomically: true, encoding: .utf8)
        let official = root.appendingPathComponent("site/ai-terms-dev-tools.txt")
        try FileManager.default.createDirectory(at: official.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "氛围编程\n具身智能\n".write(to: official, atomically: true, encoding: .utf8)
        let manager = SubscriptionManager(paths: paths)
        let added = try await manager.add(url: old.absoluteString, name: nil)
        #expect(added.feedID == nil)
        let catalog = VocabularyCatalog(version: 2, name: "AIME", homepage: nil, updated: nil, feeds: [
            .init(id: "ai-terms-dev-tools", name: "AI 与开发术语", description: "", category: "ai", entries: 2, url: official,
                  version: "2026-10-01", updated: "2026-10-01", sha256: PackageManager.sha256(of: try Data(contentsOf: official)), size: nil),
        ])
        #expect(try manager.follow(catalog) == [added.id])
        let adopted = manager.subscriptions().first!
        #expect(adopted.feedID == "ai-terms-dev-tools" && adopted.url == official && adopted.expectedSHA256 != nil)
        #expect(try await manager.update(id: adopted.id, force: true)?.entryCount == 2)
    }
}

