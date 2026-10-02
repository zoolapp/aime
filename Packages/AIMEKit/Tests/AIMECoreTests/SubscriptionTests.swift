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

    @Test(arguments: [false, true])
    func tableSignatureDetectsSameSizeAndTimestampChanges(shipped: Bool) async throws {
        try "schema_list:\n  - schema: rime_ice\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
        let manager = stubManager()
        let target: URL
        if shipped {
            target = paths.sharedDataDir!.appendingPathComponent("aime/aime_tech.tsv")
        } else {
            let added = try await manager.add(url: "https://example.invalid/feed.txt", name: nil)
            target = manager.cacheURL(added.id)
        }
        let initial = Data("原词\tyuan ci\t50\n".utf8)
        let updated = Data("原词\tyuan ci\t80\n".utf8)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try initial.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: target.path)
        let beforeAttributes = try FileManager.default.attributesOfItem(atPath: target.path)
        let before = manager.tableSignature(schemas: ["rime_ice"], items: manager.subscriptions())
        #expect(try manager.ensureTables())
        #expect(try manager.ensureTables() == false)

        try updated.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: target.path)
        let afterAttributes = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect(beforeAttributes[.modificationDate] as? Date == afterAttributes[.modificationDate] as? Date)
        #expect(beforeAttributes[.size] as? Int == afterAttributes[.size] as? Int)
        let after = manager.tableSignature(schemas: ["rime_ice"], items: manager.subscriptions())
        #expect(before != after)
        #expect(after.contains(PackageManager.sha256(of: updated)))
        #expect(try manager.ensureTables())
        let table = try String(contentsOf: paths.userDataDir.appendingPathComponent("aime_online.txt"), encoding: .utf8)
        #expect(table.contains("原词\tyuanci\t80"))

        // A timestamp-only change must not invalidate content-addressed tables.
        try FileManager.default.setAttributes([.modificationDate: timestamp.addingTimeInterval(3600)], ofItemAtPath: target.path)
        #expect(manager.tableSignature(schemas: ["rime_ice"], items: manager.subscriptions()) == after)
        #expect(try manager.ensureTables() == false)
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
    @Test(arguments: [false, true])
    func pendingUpdateDoesNotRestoreRemovedSubscription(fails: Bool) async throws {
        let manager = stubManager()
        let added = try await manager.add(url: "https://example.invalid/feed.txt", name: nil)
        let gate = SubscriptionFetchGate()
        let updating = SubscriptionManager(paths: paths, fetch: { _, _ in
            await gate.pause()
            if fails { throw SubscriptionError.http(503) }
            return .init(data: Data("新词\txin ci\t60\n".utf8), etag: "new", lastModified: nil, status: 200)
        })
        let task = Task { try await updating.update(id: added.id, force: true) }
        await gate.waitForEntry()
        try manager.remove(id: added.id)
        await gate.resume()
        #expect(try await task.value == nil)
        #expect(manager.subscriptions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: manager.cacheURL(added.id).path))
    }

    @Test(arguments: [false, true])
    func pendingUpdatePreservesIntervalAndOtherSubscriptions(fails: Bool) async throws {
        let manager = stubManager()
        let added = try await manager.add(url: "https://example.invalid/feed.txt", name: nil)
        let gate = SubscriptionFetchGate()
        let updating = SubscriptionManager(paths: paths, fetch: { _, _ in
            await gate.pause()
            if fails { throw SubscriptionError.http(503) }
            return .init(data: Data("原词\tyuan ci\t50\n新词\txin ci\t60\n".utf8), etag: "new", lastModified: nil, status: 200)
        })
        let task = Task { try await updating.update(id: added.id, force: true) }
        await gate.waitForEntry()
        try manager.setInterval(id: added.id, .weekly)
        let other = try await manager.add(url: "https://example.invalid/other.txt", name: "另一份词库")
        let savedOther = manager.subscriptions().first { $0.id == other.id }
        await gate.resume()
        let result = try await task.value
        #expect(result?.updateInterval == .weekly)
        #expect(result?.entryCount == (fails ? 1 : 2))
        #expect((result?.lastError != nil) == fails)
        #expect(manager.subscriptions().first { $0.id == added.id }?.updateInterval == .weekly)
        #expect(manager.subscriptions().first { $0.id == other.id } == savedOther)
        #expect(manager.subscriptions().count == 2)
    }

    @Test(arguments: [false, true])
    func pendingUpdateDiscardsChangedSource(checksumOnly: Bool) async throws {
        let manager = stubManager()
        let added = try await manager.add(url: "https://example.invalid/feed.txt", name: nil)
        let originalCache = try Data(contentsOf: manager.cacheURL(added.id))
        let gate = SubscriptionFetchGate()
        let updating = SubscriptionManager(paths: paths, fetch: { _, _ in
            await gate.pause()
            return .init(data: Data("新词\txin ci\t60\n".utf8), etag: "stale", lastModified: nil, status: 200)
        })
        let task = Task { try await updating.update(id: added.id, force: true) }
        await gate.waitForEntry()
        let catalog = VocabularyCatalog(version: 2, name: "AIME", homepage: nil, updated: nil, feeds: [
            .init(id: "feed", name: "词库", description: "", category: "ai", entries: nil,
                  url: checksumOnly ? added.url : URL(string: "https://example.invalid/v2/feed.txt")!,
                  version: nil, updated: nil, sha256: String(repeating: "a", count: 64), size: nil),
        ])
        try manager.follow(catalog)
        let current = manager.subscriptions()
        await gate.resume()
        #expect(try await task.value == nil)
        #expect(manager.subscriptions() == current)
        #expect(try Data(contentsOf: manager.cacheURL(added.id)) == originalCache)
    }

    private func stubManager() -> SubscriptionManager {
        SubscriptionManager(paths: paths, fetch: { _, _ in
            .init(data: Data("原词\tyuan ci\t50\n".utf8), etag: "original", lastModified: nil, status: 200)
        })
    }

    @Test func updateDueIgnoresHistoricalNewEntriesWhenNotDue() async throws {
        let manager = stubManager()
        let added = try await manager.add(url: "https://example.invalid/feed.txt", name: nil)
        let due = added.lastChecked!.addingTimeInterval(25 * 3600)
        let updating = SubscriptionManager(paths: paths, fetch: { _, etag in
            #expect(etag == "original")
            return .init(data: Data("原词\tyuan ci\t50\n新词\txin ci\t60\n".utf8), etag: "new", lastModified: nil, status: 200)
        })
        #expect(await updating.updateDue(now: due))
        #expect(manager.subscriptions().first?.newEntries == 1)
        let notDue = SubscriptionManager(paths: paths, fetch: { _, _ in
            Issue.record("未到期或仅手动订阅不应发起下载")
            throw SubscriptionError.http(500)
        })
        #expect(await notDue.updateDue(now: due.addingTimeInterval(3600)) == false)
        #expect(await notDue.updateDue(now: due.addingTimeInterval(7200)) == false)
        #expect(try await notDue.update(id: added.id, now: due.addingTimeInterval(7200))?.contentChanged == false)
        #expect(manager.subscriptions().first?.newEntries == 1)
        try manager.setInterval(id: added.id, .manual)
        #expect(await notDue.updateDue(now: due.addingTimeInterval(30 * 24 * 3600)) == false)
    }

    @Test(arguments: ["新词\txin ci\t50\n", "原词\tyuan ci\t80\n", "原词\tyuan qi\t50\n"])
    func updateDueDetectsEqualCountContentChanges(content: String) async throws {
        let manager = stubManager()
        let added = try await manager.add(url: "https://example.invalid/feed.txt", name: nil)
        let updating = SubscriptionManager(paths: paths, fetch: { _, _ in
            .init(data: Data(content.utf8), etag: nil, lastModified: nil, status: 200)
        })
        #expect(await updating.updateDue(now: added.lastChecked!.addingTimeInterval(25 * 3600)))
        #expect(manager.subscriptions().first?.entryCount == 1)
        #expect(try String(contentsOf: manager.cacheURL(added.id), encoding: .utf8) == content)
        #expect(try await updating.update(id: added.id, force: true)?.contentChanged == false)
    }

    @Test(arguments: [200, 304, 503])
    func updateDueDoesNotReportUnchangedOrFailedDownloads(status: Int) async throws {
        let manager = stubManager()
        let added = try await manager.add(url: "https://example.invalid/feed.txt", name: nil)
        let content = Data("原词\tyuan ci\t50\n新词\txin ci\t60\n".utf8)
        let initialUpdate = SubscriptionManager(paths: paths, fetch: { _, _ in
            .init(data: content, etag: "new", lastModified: nil, status: 200)
        })
        let result = try #require(await initialUpdate.update(id: added.id, force: true))
        #expect(result.contentChanged && result.item.newEntries == 1)
        let checked = SubscriptionManager(paths: paths, fetch: { _, _ in
            .init(data: status == 200 ? content : nil, etag: "new", lastModified: nil, status: status)
        })
        #expect(await checked.updateDue(now: result.item.lastChecked!.addingTimeInterval(25 * 3600)) == false)
        #expect(try Data(contentsOf: manager.cacheURL(added.id)) == content)
        #expect((manager.subscriptions().first?.lastError != nil) == (status == 503))
    }

    @Test func cacheWriteFailureDoesNotReportContentChanged() async throws {
        let manager = stubManager()
        let added = try await manager.add(url: "https://example.invalid/feed.txt", name: nil)
        try FileManager.default.removeItem(at: manager.cacheURL(added.id))
        // A directory at the cache path deterministically prevents atomic file replacement.
        try FileManager.default.createDirectory(at: manager.cacheURL(added.id), withIntermediateDirectories: true)
        let result = try #require(await manager.update(id: added.id, force: true))
        #expect(result.contentChanged == false)
        #expect(result.item.lastError != nil)
    }

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

private actor SubscriptionFetchGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { release = $0 }
    }

    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }

    func resume() {
        release?.resume()
        release = nil
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
