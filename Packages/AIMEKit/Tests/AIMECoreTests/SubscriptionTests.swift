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
        #expect(catalog.feeds.allSatisfy { $0.sha256?.count == 64 && $0.version != nil && ($0.entries ?? 0) > 0 })
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
        let source = URL(string: "https://example.invalid/feed.txt")!
        let feed = VocabularyCatalog.Feed(id: "feed", name: "词库", description: "", category: nil, entries: nil,
                                         url: source, version: nil, updated: nil, sha256: nil, size: nil)
        let added = try await manager.add(url: source.absoluteString, name: nil, feed: feed)
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

private actor SubscriptionFetchFixture {
    var response: SubscriptionManager.Response
    var urls: [URL] = []
    var etags: [String?] = []
    var metadataRequests = 0
    var catalogRequests = 0

    init(_ content: String = "示例词\tshi li ci\t50\n") {
        response = .init(data: Data(content.utf8), etag: "v1", lastModified: nil, status: 200)
    }

    func fetch(_ url: URL, _ etag: String?) -> SubscriptionManager.Response {
        urls.append(url)
        etags.append(etag)
        return response
    }

    func set(_ response: SubscriptionManager.Response) { self.response = response }
    func metadata(_ url: URL) -> Date? { metadataRequests += 1; return nil }
    func catalog(_ value: VocabularyCatalog?) -> VocabularyCatalog? { catalogRequests += 1; return value }
    func counts() -> (feeds: Int, metadata: Int, catalog: Int) { (urls.count, metadataRequests, catalogRequests) }
    func resetCounts() { urls = []; etags = []; metadataRequests = 0; catalogRequests = 0 }
}

extension SubscriptionTests {
    private var refreshDate: Date { Date(timeIntervalSince1970: 2_000_000_000) }

    private func emptyCatalog() -> VocabularyCatalog {
        .init(version: 1, name: "Test", homepage: nil, updated: nil, feeds: [])
    }

    private func seed(_ manager: SubscriptionManager, count: Int, github: Bool = false) throws -> [VocabularySubscription] {
        let items = (0..<count).map { index -> VocabularySubscription in
            let host = github ? "raw.githubusercontent.com" : "example.com"
            var item = VocabularySubscription(id: "feed\(index)", name: "Feed \(index)",
                url: URL(string: "https://\(host)/owner/words/main/feed\(index).txt")!,
                addedAt: refreshDate.addingTimeInterval(Double(index - 100)))
            if github { item.feedID = "feed\(index)" }
            return item
        }
        try manager.save(items)
        return items
    }

    @Test func refreshDetectsEqualCountChangesAndSignatureUsesActualBytes() async throws {
        try "schema_list:\n  - schema: rime_ice\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
        let fixture = SubscriptionFetchFixture("测试词\tce shi ci\t50\n")
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        let added = try await manager.add(url: "https://example.com/feed.txt", name: nil)
        #expect(try manager.ensureTables())
        let cached = manager.cacheURL(added.id)
        let timestamp = try FileManager.default.attributesOfItem(atPath: cached.path)[.modificationDate] as! Date
        let size = try Data(contentsOf: cached).count
        await fixture.set(.init(data: Data("测试词\tce shi ci\t80\n".utf8), etag: "v2", lastModified: nil, status: 200))
        let report = await manager.refresh(mode: .manual, now: refreshDate, catalog: { nil })
        #expect(report.changedIDs == [added.id] && report.errors.isEmpty)
        #expect(manager.subscriptions().first?.entryCount == 1)
        #expect(try Data(contentsOf: cached).count == size)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: cached.path)
        #expect(try manager.ensureTables())
        #expect(try String(contentsOf: paths.userDataDir.appendingPathComponent("aime_online.txt"), encoding: .utf8)
            .contains("测试词\tceshici\t80"))
        #expect(try manager.ensureTables() == false)

        // An external same-size/same-time edit also bypasses no content metadata.
        try Data("测试词\tce shi ci\t90\n".utf8).write(to: cached)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: cached.path)
        #expect(try manager.ensureTables())
        #expect(try String(contentsOf: paths.userDataDir.appendingPathComponent("aime_online.txt"), encoding: .utf8)
            .contains("测试词\tceshici\t90"))
    }

    @Test func unchangedResponsesAndSkippedChecksIgnoreHistoricalNewWords() async throws {
        let fixture = SubscriptionFetchFixture("词甲\tci jia\t50\n")
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        let added = try await manager.add(url: "https://example.com/feed.txt", name: nil)
        let content = Data("词甲\tci jia\t50\n词乙\tci yi\t50\n".utf8)
        await fixture.set(.init(data: content, etag: "v2", lastModified: nil, status: 200))
        #expect(await manager.refresh(mode: .manual, now: refreshDate, catalog: { nil }).changed)
        #expect(manager.subscriptions().first?.newEntries == 1)
        await fixture.resetCounts()
        let skipped = await manager.refresh(mode: .due, now: refreshDate.addingTimeInterval(1), catalog: { await fixture.catalog(nil) })
        #expect(skipped.checkedIDs.isEmpty && !skipped.changed)
        let skippedRequests = await fixture.counts()
        #expect(skippedRequests.feeds == 0 && skippedRequests.catalog == 0)
        let unchanged = await manager.refresh(mode: .manual, now: refreshDate.addingTimeInterval(2), catalog: { nil })
        #expect(!unchanged.changed && unchanged.errors.isEmpty)
        #expect(manager.subscriptions().first?.newEntries == 1)
        await fixture.set(.init(data: nil, etag: "v2", lastModified: nil, status: 304))
        let notModified = await manager.refresh(mode: .manual, now: refreshDate.addingTimeInterval(3), catalog: { nil })
        #expect(!notModified.changed && notModified.errors.isEmpty)
        #expect(manager.subscriptions().first?.newEntries == 1 && manager.subscriptions().first?.id == added.id)
        #expect(await manager.updateDue(now: refreshDate.addingTimeInterval(4), catalog: { nil }) == false)
    }

    @Test func manualRefreshFollowsNewCatalogEvenForManualIntervals() async throws {
        let fixture = SubscriptionFetchFixture("词甲\tci jia\t50\n")
        let old = URL(string: "https://example.com/resources/v1/terms.txt")!
        let new = URL(string: "https://example.com/resources/v2/terms.txt")!
        func feed(_ url: URL, _ data: Data) -> VocabularyCatalog.Feed {
            .init(id: "terms", name: "Terms", description: "", category: nil, entries: nil, url: url,
                  version: nil, updated: nil, sha256: PackageManager.sha256(of: data), size: nil)
        }
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        let added = try await manager.add(url: old.absoluteString, name: nil, feed: feed(old, Data("词甲\tci jia\t50\n".utf8)))
        try manager.setInterval(id: added.id, .manual)
        let data = Data("词甲\tci jia\t80\n".utf8)
        await fixture.set(.init(data: data, etag: "v2", lastModified: nil, status: 200))
        await fixture.resetCounts()
        let catalog = VocabularyCatalog(version: 2, name: "Test", homepage: nil, updated: nil, feeds: [feed(new, data)])
        let report = await manager.refresh(mode: .manual, now: refreshDate, catalog: { await fixture.catalog(catalog) })
        #expect(report.catalog == catalog && report.catalogError == nil && report.changedIDs == [added.id])
        #expect(manager.subscriptions().first?.url == new && manager.subscriptions().first?.updateInterval == .manual)
        let requestedURLs = await fixture.urls
        let requestedETags = await fixture.etags
        #expect(requestedURLs == [new] && requestedETags == [nil])
        #expect(await fixture.counts().catalog == 1)
    }

    @Test func failedCatalogStillChecksOldSourceAndPreservesCacheOnFailures() async throws {
        let fixture = SubscriptionFetchFixture()
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        let added = try await manager.add(url: "https://example.com/feed.txt", name: nil)
        let before = try Data(contentsOf: manager.cacheURL(added.id))
        await fixture.resetCounts()
        await fixture.set(.init(data: nil, etag: nil, lastModified: nil, status: 503))
        let report = await manager.refresh(mode: .manual, now: refreshDate, catalog: { await fixture.catalog(nil) })
        #expect(report.catalogError != nil && report.errors[added.id]?.contains("503") == true && !report.changed)
        #expect(try Data(contentsOf: manager.cacheURL(added.id)) == before)
        let failedRequests = await fixture.counts()
        #expect(failedRequests.feeds == 1 && failedRequests.catalog == 1)
        #expect(manager.subscriptions().first?.lastError == report.errors[added.id])
        await fixture.set(.init(data: nil, etag: nil, lastModified: nil, status: 200))
        let empty = await manager.refresh(mode: .manual, now: refreshDate.addingTimeInterval(1), catalog: { nil })
        #expect(empty.errors[added.id] != nil && !empty.changed)
        #expect(try Data(contentsOf: manager.cacheURL(added.id)) == before)
    }

    @Test func checksumAndSizeFailuresDoNotReplaceUsableCache() async throws {
        let fixture = SubscriptionFetchFixture()
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        let data = Data("示例词\tshi li ci\t50\n".utf8)
        let url = URL(string: "https://example.com/feed.txt")!
        let feed = VocabularyCatalog.Feed(id: "feed", name: "Feed", description: "", category: nil, entries: nil, url: url,
            version: nil, updated: nil, sha256: PackageManager.sha256(of: data), size: nil)
        let added = try await manager.add(url: url.absoluteString, name: nil, feed: feed)
        await fixture.set(.init(data: Data("其他词\tqi ta ci\t50\n".utf8), etag: nil, lastModified: nil, status: 200))
        let checksum = await manager.refresh(mode: .manual, now: refreshDate, catalog: { nil })
        #expect(checksum.errors[added.id]?.contains("SHA-256") == true && !checksum.changed)
        await fixture.set(.init(data: Data(repeating: 0, count: SubscriptionManager.maxBytes + 1), etag: nil, lastModified: nil, status: 200))
        let oversized = await manager.refresh(mode: .manual, now: refreshDate.addingTimeInterval(1), catalog: { nil })
        #expect(oversized.errors[added.id]?.contains("20 MB") == true && !oversized.changed)
        #expect(try Data(contentsOf: manager.cacheURL(added.id)) == data)
        #expect(await fixture.counts().feeds == 3) // add + two checks; no retries
    }

    @Test func twentyMiBLimitIsInclusive() async throws {
        let fixture = SubscriptionFetchFixture()
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        let added = try await manager.add(url: "https://example.com/feed.txt", name: nil)
        var limit = Data("边界词\tbian jie ci\t50\n#".utf8)
        limit.append(Data(repeating: 0x61, count: SubscriptionManager.maxBytes - limit.count))
        await fixture.set(.init(data: limit, etag: nil, lastModified: nil, status: 200))
        let accepted = await manager.refresh(mode: .manual, now: refreshDate, catalog: { nil })
        #expect(accepted.changed && accepted.errors.isEmpty)
        #expect(try Data(contentsOf: manager.cacheURL(added.id)).count == SubscriptionManager.maxBytes)
    }

    @Test func missingCacheDropsETagAndRejects304WithoutRetry() async throws {
        let fixture = SubscriptionFetchFixture()
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        let added = try await manager.add(url: "https://example.com/feed.txt", name: nil)
        try FileManager.default.removeItem(at: manager.cacheURL(added.id))
        await fixture.resetCounts()
        await fixture.set(.init(data: nil, etag: "v1", lastModified: nil, status: 304))
        let report = await manager.refresh(mode: .manual, now: refreshDate, catalog: { nil })
        #expect(report.errors[added.id] != nil && !report.changed)
        let requestedETags = await fixture.etags
        let requests = await fixture.counts()
        #expect(requestedETags == [nil] && requests.feeds == 1)
        #expect(!FileManager.default.fileExists(atPath: manager.cacheURL(added.id).path))
    }

    @Test func rejectsNewSubscriptionAtLimitButKeepsExistingURLs() async throws {
        let fixture = SubscriptionFetchFixture()
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        let original = try seed(manager, count: SubscriptionManager.maxSubscriptions)
        let existing = try await manager.add(url: original[0].url.absoluteString, name: nil)
        #expect(existing.id == original[0].id)
        do {
            _ = try await manager.add(url: "https://example.com/new.txt", name: nil)
            Issue.record("Expected the subscription limit to reject the new URL")
        } catch SubscriptionError.limitReached(let limit) {
            #expect(limit == 32)
        }
        #expect(manager.subscriptions() == original)
        #expect(await fixture.counts().feeds == 0)
    }

    @Test func legacyLongListsRotateInBoundedBatchesAndRemainIntact() async throws {
        let fixture = SubscriptionFetchFixture()
        var manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        manager.fetchCommitDate = { await fixture.metadata($0) }
        let original = try seed(manager, count: 40, github: true)
        let catalog = emptyCatalog()
        let first = await manager.refresh(mode: .due, now: refreshDate, catalog: { await fixture.catalog(catalog) })
        #expect(first.checkedIDs == original.prefix(32).map(\.id) && first.deferredCount == 8)
        #expect(first.changedIDs.count == 32 && first.errors.isEmpty)
        let requests = await fixture.counts()
        #expect(requests.feeds == 32 && requests.metadata == 32 && requests.catalog == 1)
        #expect(requests.feeds + requests.metadata + requests.catalog == SubscriptionManager.maxRequestsPerRefresh)
        await fixture.resetCounts()
        let next = await manager.refresh(mode: .due, now: refreshDate.addingTimeInterval(1), catalog: { await fixture.catalog(catalog) })
        #expect(next.checkedIDs == original.suffix(8).map(\.id) && next.deferredCount == 0)
        #expect(manager.subscriptions().count == 40)
        #expect(original.allSatisfy { FileManager.default.fileExists(atPath: manager.cacheURL($0.id).path) })
        let nextRequests = await fixture.counts()
        #expect(nextRequests.feeds == 8 && nextRequests.metadata == 8 && nextRequests.catalog == 1)
    }

    @Test func adoptionPersistsFeedIDWithoutChangingSourceAndRejectsPrivateNamesakes() async throws {
        let fixture = SubscriptionFetchFixture()
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        let same = URL(string: "https://example.com/owner/words/main/terms.txt")!
        let added = try await manager.add(url: same.absoluteString, name: nil)
        let sameFeed = VocabularyCatalog.Feed(id: "terms", name: "Terms", description: "", category: nil, entries: nil,
            url: same, version: nil, updated: nil, sha256: nil, size: nil)
        let catalog = VocabularyCatalog(version: 1, name: "Test", homepage: nil, updated: nil, feeds: [sameFeed])
        #expect(try manager.follow(catalog).isEmpty)
        #expect(manager.subscriptions().first?.feedID == "terms")
        let privateFeed = try await manager.add(url: "https://example.com/private/words/main/terms.txt", name: nil)
        let localFeed = try await manager.add(url: root.appendingPathComponent("terms.txt").absoluteString, name: nil)
        #expect(try manager.follow(catalog).isEmpty)
        #expect(manager.subscriptions().first(where: { $0.id == privateFeed.id })?.feedID == nil)
        #expect(manager.subscriptions().first(where: { $0.id == localFeed.id })?.feedID == nil)
        #expect(manager.subscriptions().first(where: { $0.id == added.id })?.feedID == "terms")
    }

    @Test func refreshDoesNotResurrectFeedRemovedWhileFetching() async throws {
        let localPaths = paths
        let initial = SubscriptionManager(paths: paths)
        let original = try seed(initial, count: 1)[0]
        let manager = SubscriptionManager(paths: paths) { _, _ in
            try SubscriptionManager(paths: localPaths).remove(id: original.id)
            return .init(data: Data("旧响应\tjiu xiang ying\t50\n".utf8), etag: nil, lastModified: nil, status: 200)
        }
        let report = await manager.refresh(mode: .manual, now: refreshDate, catalog: { nil })
        #expect(manager.subscriptions().isEmpty && !report.changed)
        #expect(!FileManager.default.fileExists(atPath: manager.cacheURL(original.id).path))
    }

    @Test func refreshPreservesEditsMadeDuringDownloadAndMetadataRequests() async throws {
        let localPaths = paths
        let initial = SubscriptionManager(paths: paths)
        let original = try seed(initial, count: 1, github: true)[0]
        var manager = SubscriptionManager(paths: paths) { _, _ in
            try SubscriptionManager(paths: localPaths).setInterval(id: original.id, .weekly)
            return .init(data: Data("示例词\tshi li ci\t50\n".utf8), etag: "v1", lastModified: nil, status: 200)
        }
        manager.fetchCommitDate = { _ in
            let peer = SubscriptionManager(paths: localPaths)
            var items = peer.subscriptions()
            items[0].name = "Renamed"
            items[0].interval = .manual
            items.append(.init(id: "new", name: "New", url: URL(string: "https://example.com/new.txt")!, addedAt: original.addedAt))
            try peer.save(items)
            return nil
        }
        let report = await manager.refresh(mode: .manual, now: refreshDate, catalog: { nil })
        let after = manager.subscriptions()
        #expect(report.changed && report.errors.isEmpty && after.count == 2)
        #expect(after[0].name == "Renamed" && after[0].updateInterval == .manual && after[0].entryCount == 1)
        #expect(after[1].id == "new")
    }

    @Test func obsoleteResponseDoesNotOverwriteNewSource() async throws {
        let localPaths = paths
        let initial = SubscriptionManager(paths: paths)
        let original = try seed(initial, count: 1)[0]
        let newURL = URL(string: "https://example.com/new.txt")!
        let manager = SubscriptionManager(paths: paths) { _, _ in
            let peer = SubscriptionManager(paths: localPaths)
            var items = peer.subscriptions()
            items[0].url = newURL
            try peer.save(items)
            return .init(data: Data("旧响应\tjiu xiang ying\t50\n".utf8), etag: "old", lastModified: nil, status: 200)
        }
        let report = await manager.refresh(mode: .manual, now: refreshDate, catalog: { nil })
        #expect(!report.changed && manager.subscriptions().first?.url == newURL)
        #expect(manager.subscriptions().first?.lastChecked == nil)
        #expect(!FileManager.default.fileExists(atPath: manager.cacheURL(original.id).path))
    }

    @Test func futureTimestampForceCheckStillDownloads() async throws {
        let fixture = SubscriptionFetchFixture()
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        var original = try seed(manager, count: 1)
        original[0].lastChecked = refreshDate.addingTimeInterval(25 * 3600)
        original[0].interval = .manual
        try manager.save(original)
        let checked = try await manager.update(id: original[0].id, force: true, now: refreshDate)
        #expect(checked?.entryCount == 1 && checked?.lastError == nil)
        #expect(checked?.lastChecked == refreshDate)
        #expect(await fixture.counts().feeds == 1)
        #expect(FileManager.default.fileExists(atPath: manager.cacheURL(original[0].id).path))
    }

    @Test func newerCheckDuringFetchRejectsObsoleteResponse() async throws {
        let localPaths = paths
        let initial = SubscriptionManager(paths: paths)
        let original = try seed(initial, count: 1)[0]
        let newerDate = refreshDate.addingTimeInterval(1)
        let newData = Data("示例词\tshi li ci\t90\n".utf8)
        let manager = SubscriptionManager(paths: paths) { _, _ in
            let peer = SubscriptionManager(paths: localPaths)
            var items = peer.subscriptions()
            items[0].lastChecked = newerDate
            items[0].entryCount = 1
            items[0].etag = "new"
            try FileManager.default.createDirectory(at: peer.cacheURL(original.id).deletingLastPathComponent(), withIntermediateDirectories: true)
            try newData.write(to: peer.cacheURL(original.id))
            try peer.save(items)
            return .init(data: Data("示例词\tshi li ci\t50\n".utf8), etag: "old", lastModified: nil, status: 200)
        }
        let checked = try await manager.update(id: original.id, force: true, now: refreshDate)
        #expect(checked?.lastChecked == newerDate && checked?.etag == "new")
        #expect(try Data(contentsOf: manager.cacheURL(original.id)) == newData)
        #expect(manager.subscriptions().first?.lastChecked == newerDate)
    }

    @Test func refreshReportsManifestSaveFailures() async throws {
        let localPaths = paths
        let initial = SubscriptionManager(paths: paths)
        let original = try seed(initial, count: 1, github: true)[0]
        var manager = SubscriptionManager(paths: paths) { _, _ in
            .init(data: Data("示例词\tshi li ci\t50\n".utf8), etag: nil, lastModified: nil, status: 200)
        }
        // Pre-create the lock and writable cache directory so only the manifest's
        // parent becomes read-only during metadata await, before the commit lock.
        try manager.setInterval(id: original.id, .daily)
        try FileManager.default.createDirectory(at: manager.cacheURL(original.id).deletingLastPathComponent(), withIntermediateDirectories: true)
        manager.fetchCommitDate = { _ in
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: localPaths.aimeDir.path)
            return nil
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.aimeDir.path) }
        let report = await manager.refresh(mode: .manual, now: refreshDate, catalog: { nil })
        #expect(report.errors[original.id] != nil)
        #expect(report.changedIDs == [original.id]) // downloaded bytes are still usable
        #expect(manager.subscriptions().first?.lastChecked == nil)
    }

    @Test func mixedBatchReportsFailedFeedWhileKeepingSuccessfulChange() async throws {
        let manager = SubscriptionManager(paths: paths) { url, _ in
            url.lastPathComponent == "feed0.txt"
                ? .init(data: Data("示例词\tshi li ci\t80\n".utf8), etag: nil, lastModified: nil, status: 200)
                : .init(data: nil, etag: nil, lastModified: nil, status: 503)
        }
        let original = try seed(manager, count: 2)
        try FileManager.default.createDirectory(at: manager.cacheURL(original[0].id).deletingLastPathComponent(), withIntermediateDirectories: true)
        let before = Data("示例词\tshi li ci\t50\n".utf8)
        for item in original { try before.write(to: manager.cacheURL(item.id)) }
        let report = await manager.refresh(mode: .due, now: refreshDate, catalog: { nil })
        #expect(report.checkedIDs == original.map(\.id) && report.changedIDs == [original[0].id])
        #expect(report.errors.count == 1 && report.errors[original[1].id]?.contains("503") == true)
        #expect(try Data(contentsOf: manager.cacheURL(original[1].id)) == before)
        #expect(manager.subscriptions()[1].lastError == report.errors[original[1].id])
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
        let old = URL(string: "https://example.com/owner/words/old/ai-terms-dev-tools.txt")!
        let official = URL(string: "https://example.com/owner/words/new/ai-terms-dev-tools.txt")!
        let officialData = Data("氛围编程\n具身智能\n".utf8)
        let manager = SubscriptionManager(paths: paths) { url, _ in
            .init(data: url == official ? officialData : Data("氛围编程\n".utf8), etag: nil, lastModified: nil, status: 200)
        }
        let added = try await manager.add(url: old.absoluteString, name: nil)
        #expect(added.feedID == nil)
        let catalog = VocabularyCatalog(version: 2, name: "AIME", homepage: nil, updated: nil, feeds: [
            .init(id: "ai-terms-dev-tools", name: "AI 与开发术语", description: "", category: "ai", entries: 2, url: official,
                  version: "2026-10-01", updated: "2026-10-01", sha256: PackageManager.sha256(of: officialData), size: nil),
        ])
        #expect(try manager.follow(catalog) == [added.id])
        let adopted = manager.subscriptions().first!
        #expect(adopted.feedID == "ai-terms-dev-tools" && adopted.url == official && adopted.expectedSHA256 != nil)
        #expect(try await manager.update(id: adopted.id, force: true)?.entryCount == 2)
    }
}
