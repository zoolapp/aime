public import Foundation
import CryptoKit

/// One vocabulary entry: text + space-separated full pinyin (or a Latin code).
public struct VocabularyEntry: Sendable, Hashable {
    public var text: String
    public var pinyin: String
    public var weight: Int

    public init(text: String, pinyin: String, weight: Int = 50) {
        self.text = text
        self.pinyin = pinyin
        self.weight = weight
    }
}

public enum VocabularyParser {
    /// Parses a Rime `dict.yaml`, a `text<TAB>code[<TAB>weight]` table, or a plain word
    /// list (pinyin computed locally). Comment and header lines are skipped.
    public static func parse(_ content: String) -> [VocabularyEntry] {
        var lines = content.components(separatedBy: .newlines)
        if let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "..." }),
           lines.prefix(end).contains(where: { $0.hasPrefix("name:") || $0 == "---" }) {
            lines = Array(lines[(end + 1)...])
        }
        var seen = Set<String>()
        var entries: [VocabularyEntry] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let columns = line.components(separatedBy: "\t")
            let text = columns[0].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.count <= 32 else { continue }
            var code = columns.count > 1 ? columns[1].trimmingCharacters(in: .whitespaces) : ""
            // `text code weight`, or `text code tag weight` (aime_tech): first numeric column.
            let weight = columns.dropFirst(2).lazy.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.first ?? 50
            if code.isEmpty || Int(code) != nil { code = pinyin(for: text) ?? "" }
            guard !code.isEmpty, seen.insert("\(text)\t\(code)").inserted else { continue }
            entries.append(VocabularyEntry(text: text, pinyin: code.lowercased(), weight: weight))
        }
        return entries
    }

    /// Space-separated toneless pinyin for Chinese text; lowercase alphanumerics for Latin.
    public static func pinyin(for text: String) -> String? {
        let hasHan = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        if !hasHan {
            let code = text.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            return code.isEmpty ? nil : code
        }
        guard let toned = text.applyingTransform(.mandarinToLatin, reverse: false) else { return nil }
        let marked = toned.lowercased().replacingOccurrences(of: #"[üǖǘǚǜ]"#, with: "v", options: .regularExpression)
        guard let plain = marked.applyingTransform(.stripDiacritics, reverse: false) else { return nil }
        let syllables = plain.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return syllables.isEmpty ? nil : syllables.joined(separator: " ")
    }
}

/// A user-provided online vocabulary (e.g. a raw GitHub text file).
public struct VocabularySubscription: Sendable, Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var url: URL
    public var addedAt: Date
    public var lastChecked: Date?
    /// When the remote file itself last changed (GitHub commit date or Last-Modified).
    public var remoteUpdated: Date?
    public var etag: String?
    public var entryCount: Int = 0
    public var newEntries: Int = 0
    public var recentWords: [String] = []
    public var lastError: String?
    /// Set when subscribed from the official catalog: the feed id and the checksum the
    /// downloaded file must have (both follow the catalog when it publishes a new version).
    public var feedID: String?
    public var expectedSHA256: String?
    /// How often the automatic check may download it (absent in older files = daily).
    public var interval: UpdateInterval?

    public enum UpdateInterval: String, Sendable, Codable, CaseIterable, Hashable {
        case daily, weekly, manual

        public var seconds: TimeInterval? {
            switch self {
            case .daily: 24 * 3600
            case .weekly: 7 * 24 * 3600
            case .manual: nil
            }
        }

        public var title: String {
            switch self {
            case .daily: "每天"
            case .weekly: "每周"
            case .manual: "仅手动"
            }
        }
    }

    public var updateInterval: UpdateInterval { interval ?? .daily }
}

public enum SubscriptionError: Error, CustomStringConvertible {
    case invalidURL
    case tooLarge
    case empty
    case http(Int)
    case checksum

    public var description: String {
        switch self {
        case .checksum: "下载的文件与词库目录登记的 SHA-256 不一致，未使用"
        case .invalidURL: "请输入 http(s) 开头的词库地址"
        case .tooLarge: "词库文件超过 20 MB 上限"
        case .empty: "没有解析到词条（支持 RIME dict.yaml、词条<Tab>编码 或 每行一个词）"
        case let .http(code): "下载失败（HTTP \(code)）"
        }
    }
}

/// Downloads subscriptions, merges them with the bundled aime_tech vocabulary and writes
/// one text table per input layout (full pinyin, 小鹤双拼…) mounted into every enabled schema.
public struct SubscriptionManager: Sendable {
    public static let automaticInterval: TimeInterval = 12 * 3600
    public static let maxBytes = 20 << 20
    public static let tableName = "aime_online"

    public struct Response: Sendable {
        public var data: Data?          // nil when not modified
        public var etag: String?
        public var lastModified: Date?
        public var status: Int
    }

    /// Per-call outcome; historical newEntries remains display metadata on the item.
    @dynamicMemberLookup
    public struct UpdateResult: Sendable {
        public let item: VocabularySubscription
        public let contentChanged: Bool

        /// Preserve item field reads for existing CLI/settings callers.
        public subscript<Value>(dynamicMember keyPath: KeyPath<VocabularySubscription, Value>) -> Value {
            item[keyPath: keyPath]
        }
    }

    public let paths: AIMEPaths
    /// (url, etag) → response. Injected in tests.
    public var fetch: @Sendable (URL, String?) async throws -> Response

    public init(paths: AIMEPaths, fetch: (@Sendable (URL, String?) async throws -> Response)? = nil) {
        self.paths = paths
        self.fetch = fetch ?? Self.liveFetch
    }

    var listURL: URL { paths.aimeDir.appendingPathComponent("subscriptions.json") }
    func cacheURL(_ id: String) -> URL { paths.aimeDir.appendingPathComponent("subscriptions/\(id).txt") }

    public func subscriptions() -> [VocabularySubscription] {
        guard let data = try? Data(contentsOf: listURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([VocabularySubscription].self, from: data)) ?? []
    }

    func save(_ list: [VocabularySubscription]) throws {
        try FileManager.default.createDirectory(at: paths.aimeDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(list).write(to: listURL, options: .atomic)
    }

    /// Serialize subscription metadata/cache commits across the IME and settings processes.
    /// This separate lock is never held over a network await or a workspace deploy.
    private func withSubscriptionLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: paths.aimeDir, withIntermediateDirectories: true)
        let fd = open(paths.aimeDir.appendingPathComponent(".subscriptions.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// github.com/<o>/<r>/blob/<ref>/<path> → raw.githubusercontent.com/<o>/<r>/<ref>/<path>
    public static func normalize(_ string: String) -> URL? {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("https://github.com/"), text.contains("/blob/") {
            text = text.replacingOccurrences(of: "https://github.com/", with: "https://raw.githubusercontent.com/")
                .replacingOccurrences(of: "/blob/", with: "/")
        }
        guard let url = URL(string: text), ["http", "https", "file"].contains(url.scheme ?? "") else { return nil }
        return url
    }

    @discardableResult
    public func add(url string: String, name: String?, feed: VocabularyCatalog.Feed? = nil) async throws -> VocabularySubscription {
        guard let url = Self.normalize(string) else { throw SubscriptionError.invalidURL }
        let (subscription, inserted) = try withSubscriptionLock {
            var list = subscriptions()
            if let existing = list.first(where: { $0.url == url }) { return (existing, false) }
            let base = url.deletingPathExtension().lastPathComponent.lowercased().filter { $0.isLetter || $0.isNumber }
            var id = base.isEmpty ? "sub" : String(base.prefix(24))
            while list.contains(where: { $0.id == id }) { id += "x" }
            var subscription = VocabularySubscription(id: id, name: name?.isEmpty == false ? name! : url.lastPathComponent,
                                                      url: url, addedAt: Date())
            subscription.feedID = feed?.id
            subscription.expectedSHA256 = feed?.sha256
            list.append(subscription)
            try save(list)
            return (subscription, true)
        }
        guard inserted else { return subscription }
        return try await update(id: subscription.id, force: true)?.item ?? subscription
    }

    public func remove(id: String) throws {
        try withSubscriptionLock {
            try save(subscriptions().filter { $0.id != id })
            try? FileManager.default.removeItem(at: cacheURL(id))
        }
    }

    public func setInterval(id: String, _ interval: VocabularySubscription.UpdateInterval) throws {
        try withSubscriptionLock {
            var list = subscriptions()
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].interval = interval
            try save(list)
        }
    }

    /// Points catalog subscriptions at the catalog's current file and checksum. Returns
    /// the ids whose file changed (a new version to download).
    @discardableResult
    public func follow(_ catalog: VocabularyCatalog) throws -> [String] {
        return try withSubscriptionLock {
            var list = subscriptions()
            var changed: [String] = []
            for index in list.indices {
                // Subscriptions made before feeds carried ids (or by pasting a link to an
                // official file) are adopted when the file name matches a catalog feed.
                if list[index].feedID == nil,
                   let match = catalog.feeds.first(where: { $0.url.lastPathComponent == list[index].url.lastPathComponent }) {
                    list[index].feedID = match.id
                }
                guard let feedID = list[index].feedID, let feed = catalog.feeds.first(where: { $0.id == feedID }) else { continue }
                if list[index].url != feed.url || list[index].expectedSHA256 != feed.sha256 {
                    list[index].url = feed.url
                    list[index].expectedSHA256 = feed.sha256
                    list[index].etag = nil
                    changed.append(list[index].id)
                }
            }
            if !changed.isEmpty { try save(list) }
            return changed
        }
    }

    /// Updates one subscription. Without `force`, respects its update interval.
    /// contentChanged is true only after different cache bytes were successfully written.
    @discardableResult
    public func update(id: String, force: Bool = false, now: Date = Date()) async throws -> UpdateResult? {
        guard let requested = subscriptions().first(where: { $0.id == id }) else { return nil }
        if !force {
            guard let interval = requested.updateInterval.seconds else { return UpdateResult(item: requested, contentChanged: false) } // 仅手动
            if let last = requested.lastChecked, now.timeIntervalSince(last) < interval {
                return UpdateResult(item: requested, contentChanged: false)
            }
        }
        let fetched: Result<Response, any Error>
        var commitDate: Date?
        do {
            let response = try await fetch(requested.url, requested.etag)
            guard (200..<300).contains(response.status) || response.status == 304 else { throw SubscriptionError.http(response.status) }
            commitDate = try? await Self.githubCommitDate(for: requested.url)
            fetched = .success(response)
        } catch {
            fetched = .failure(error)
        }
        return try withSubscriptionLock {
            // Re-read after every network await; never resurrect a removed or retargeted feed.
            var list = subscriptions()
            guard let index = list.firstIndex(where: { $0.id == id }),
                  list[index].url == requested.url,
                  list[index].expectedSHA256 == requested.expectedSHA256 else { return nil }
            // Start with the current item so edits to interval/name/catalog fields survive.
            var item = list[index]
            item.lastChecked = now
            var contentChanged = false
            do {
                let response = try fetched.get()
                if let data = response.data {
                    guard data.count <= Self.maxBytes else { throw SubscriptionError.tooLarge }
                    let entries = VocabularyParser.parse(String(decoding: data, as: UTF8.self))
                    guard !entries.isEmpty else { throw SubscriptionError.empty }
                    if let expected = item.expectedSHA256, PackageManager.sha256(of: data) != expected.lowercased() {
                        throw SubscriptionError.checksum
                    }
                    let previousData = try? Data(contentsOf: cacheURL(id))
                    let previous = Set(VocabularyParser.parse(previousData.map { String(decoding: $0, as: UTF8.self) } ?? "").map(\.text))
                    let added = entries.map(\.text).filter { !previous.contains($0) }
                    if previousData != data {
                        try FileManager.default.createDirectory(at: cacheURL(id).deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: cacheURL(id), options: .atomic)
                        contentChanged = true
                    }
                    item.entryCount = entries.count
                    item.newEntries = previous.isEmpty ? 0 : added.count
                    if !previous.isEmpty, !added.isEmpty { item.recentWords = Array(added.prefix(20)) }
                    item.etag = response.etag
                }
                item.remoteUpdated = commitDate ?? response.lastModified ?? item.remoteUpdated
                item.lastError = nil
            } catch {
                item.lastError = String(describing: error)
            }
            list[index] = item
            try save(list)
            return UpdateResult(item: item, contentChanged: contentChanged)
        }
    }

    /// Updates every subscription that is due (automatic mode). Catalog subscriptions
    /// first follow the catalog (one small request) so a new version is what gets fetched.
    public func updateDue(now: Date = Date(), catalog: (() async -> VocabularyCatalog?)? = nil) async -> Bool {
        var changed = false
        let due = subscriptions().filter { item in
            guard let interval = item.updateInterval.seconds else { return false }
            return item.lastChecked.map { now.timeIntervalSince($0) >= interval } ?? true
        }
        if due.contains(where: { $0.feedID != nil }), let fresh = await (catalog ?? { try? await VocabularyCatalog.refresh(paths) })() {
            try? follow(fresh)
        }
        for item in subscriptions() {
            if let result = try? await update(id: item.id, force: false, now: now), result.contentChanged {
                changed = true
            }
        }
        return changed
    }

    // MARK: - Tables

    /// All vocabulary: bundled aime_tech (SharedSupport/aime/aime_tech.tsv) + subscriptions.
    public func allEntries() -> [VocabularyEntry] {
        var entries: [VocabularyEntry] = []
        if let shipped = paths.sharedDataDir?.appendingPathComponent("aime/aime_tech.tsv"),
           let text = try? String(contentsOf: shipped, encoding: .utf8) {
            entries += VocabularyParser.parse(text)
        }
        for item in subscriptions() {
            if let text = try? String(contentsOf: cacheURL(item.id), encoding: .utf8) {
                entries += VocabularyParser.parse(text)
            }
        }
        return entries
    }

    public static func tableFileName(for layout: DoublePinyin?) -> String {
        layout.map { "\(tableName)_\($0.rawValue).txt" } ?? "\(tableName).txt"
    }

    /// Writes the per-layout tables and mounts them into `schemas` via the generated
    /// layer. Returns the number of entries written.
    @discardableResult
    public func rebuild(schemas: [String]) throws -> Int {
        // Same word from several sources: keep one row per (text, pinyin), highest weight.
        var seen: [String: Int] = [:]
        var entries: [VocabularyEntry] = []
        for entry in allEntries() {
            let key = entry.text + "\t" + entry.pinyin
            if let index = seen[key] {
                if entry.weight > entries[index].weight { entries[index] = entry }
            } else {
                seen[key] = entries.count
                entries.append(entry)
            }
        }
        let layouts: [DoublePinyin?] = [nil] + DoublePinyin.allCases
        for layout in layouts {
            var lines = [
                "# Rime table", "# coding: utf-8", "#@/db_name\t\(Self.tableFileName(for: layout))", "#@/db_type\ttabledb", "#",
                "# Generated by AIME from bundled and subscribed vocabularies — do not edit.", "#", "# 此行之后不能写注释",
            ]
            for entry in entries {
                let isLatin = !entry.pinyin.contains(" ") && !entry.text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                let code: String? = if isLatin { entry.pinyin }
                    else if let layout { layout.code(forPinyin: entry.pinyin) }
                    else { entry.pinyin.replacingOccurrences(of: " ", with: "") }
                if let code, !code.isEmpty { lines.append("\(entry.text)\t\(code)\t\(entry.weight)") }
            }
            try (lines.joined(separator: "\n") + "\n").write(
                to: paths.userDataDir.appendingPathComponent(Self.tableFileName(for: layout)), atomically: true, encoding: .utf8)
        }
        let layers = ConfigLayers(paths: paths)
        // Schemas whose codes are not pinyin (t9, shape-based, other double pinyin layouts)
        // cannot type these tables; make sure an older mount is gone.
        for schema in schemas where !Self.canMount(schema) && layers.generatedValue(.schema(schema), keypath: Self.tableName) != nil {
            try layers.updateGenerated(.schema(schema)) { patch in
                patch.removeAll { $0.key == Self.tableName }
                let translator = ConfigValue.string("table_translator@\(Self.tableName)")
                if let index = patch.firstIndex(where: { $0.key == "engine/translators/+" }) {
                    let rest = (patch[index].value.listValue ?? []).filter { $0 != translator }
                    if rest.isEmpty { patch.remove(at: index) } else { patch[index].value = .list(rest) }
                }
            }
        }
        for schema in schemas where Self.canMount(schema) {
            let file = Self.tableFileName(for: DoublePinyin.layout(forSchema: schema))
            try layers.updateGenerated(.schema(schema)) { patch in
                patch.removeAll { $0.key == Self.tableName }
                patch.append(.init(Self.tableName, .map([
                    .init("dictionary", ""), .init("user_dict", .string(String(file.dropLast(4)))), .init("db_class", "stabledb"),
                    .init("enable_completion", false), .init("enable_sentence", false),
                    .init("initial_quality", 6), .init("comment_format", .list([])),
                ])))
                let translator = ConfigValue.string("table_translator@\(Self.tableName)")
                if !patch.contains(where: { $0.key == "engine/translators/+" && ($0.value.listValue ?? []).contains(translator) }) {
                    let existing = patch.firstIndex { $0.key == "engine/translators/+" }
                    if let existing {
                        patch[existing].value = .list((patch[existing].value.listValue ?? []) + [translator])
                    } else {
                        patch.append(.init("engine/translators/+", .list([translator])))
                    }
                }
            }
        }
        return entries.count
    }

    /// Full pinyin schemas and double pinyin layouts AIME can convert to.
    public static func canMount(_ schema: String) -> Bool {
        if DoublePinyin.layout(forSchema: schema) != nil { return true }
        let nonPinyin = ["double_pinyin", "t9", "wubi", "cangjie", "stroke", "zhengma", "array", "bopomofo", "jyut"]
        return !nonPinyin.contains { schema.hasPrefix($0) }
    }

    /// Called before every deploy: (re)generates the tables and mounts when the inputs
    /// changed (bundled vocabulary, subscriptions, enabled schemas). Cheap when nothing did.
    @discardableResult
    public func ensureTables() throws -> Bool {
        let hasShipped = paths.sharedDataDir.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("aime/aime_tech.tsv").path)
        } ?? false
        let items = subscriptions()
        let signatureURL = paths.aimeDir.appendingPathComponent("subscriptions/.signature")
        guard hasShipped || !items.isEmpty else {
            // Nothing subscribed (any more): empty the tables once, keep the mounts cheap.
            guard FileManager.default.fileExists(atPath: signatureURL.path) else { return false }
            try rebuild(schemas: mountSchemas())
            try? FileManager.default.removeItem(at: signatureURL)
            return true
        }
        let schemas = mountSchemas()
        let signature = tableSignature(schemas: schemas, items: items)
        let tablesExist = ([nil] + DoublePinyin.allCases).allSatisfy {
            FileManager.default.fileExists(atPath: paths.userDataDir.appendingPathComponent(Self.tableFileName(for: $0)).path)
        }
        // The generated layer can be deleted by hand ("safe to delete"): re-mount if needed.
        let layers = ConfigLayers(paths: paths)
        let mounted = schemas.filter(Self.canMount).allSatisfy {
            layers.generatedValue(.schema($0), keypath: Self.tableName) != nil
        }
        if tablesExist, mounted, (try? String(contentsOf: signatureURL, encoding: .utf8)) == signature { return false }
        try rebuild(schemas: schemas)
        try FileManager.default.createDirectory(at: signatureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try signature.write(to: signatureURL, atomically: true, encoding: .utf8)
        return true
    }

    /// Enabled schemas; before the first build, the schema list of default.yaml.
    func mountSchemas() -> [String] {
        let pending = SettingsStore(paths: paths).pendingSchemas()
        if !pending.isEmpty { return pending }
        for dir in [paths.userDataDir, paths.sharedDataDir].compactMap(\.self) {
            if let config = try? ConfigValue.load(contentsOf: dir.appendingPathComponent("default.yaml")) {
                let list = (config.value(at: "schema_list")?.listValue ?? []).compactMap { $0["schema"]?.stringValue }
                if !list.isEmpty { return list }
            }
        }
        return []
    }

    func tableSignature(schemas: [String], items: [VocabularySubscription]) -> String {
        func digest(_ url: URL) -> String {
            guard let data = try? Data(contentsOf: url) else { return "missing" }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        var parts = ["v2", schemas.sorted().joined(separator: ",")]
        if let shipped = paths.sharedDataDir?.appendingPathComponent("aime/aime_tech.tsv") { parts.append(digest(shipped)) }
        for item in items.sorted(by: { $0.id < $1.id }) { parts.append("\(item.id)=\(digest(cacheURL(item.id)))") }
        return parts.joined(separator: "|")
    }

    // MARK: - Network

    static let liveFetch: @Sendable (URL, String?) async throws -> Response = { url, etag in
        if url.isFileURL {
            return Response(data: try Data(contentsOf: url), etag: nil, lastModified: nil, status: 200)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        // Streamed so an oversized file is dropped at the limit instead of filling memory.
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if response.expectedContentLength > Int64(maxBytes) { throw SubscriptionError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw SubscriptionError.tooLarge }
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let lastModified = (http?.value(forHTTPHeaderField: "Last-Modified")).flatMap(Self.httpDate)
        return Response(data: status == 304 ? nil : data, etag: http?.value(forHTTPHeaderField: "ETag"),
                        lastModified: lastModified, status: status)
    }

    static func httpDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }

    /// Last commit date of a raw.githubusercontent.com file (one API call).
    static func githubCommitDate(for url: URL) async throws -> Date? {
        guard url.host == "raw.githubusercontent.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4 else { return nil }
        let (owner, repo, ref) = (parts[0], parts[1], parts[2])
        let path = parts[3...].joined(separator: "/")
        var components = URLComponents(string: "https://api.github.com/repos/\(owner)/\(repo)/commits")!
        components.queryItems = [.init(name: "path", value: path), .init(name: "sha", value: ref), .init(name: "per_page", value: "1")]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let commit = array.first?["commit"] as? [String: Any],
              let committer = commit["committer"] as? [String: Any],
              let date = committer["date"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: date)
    }
}
