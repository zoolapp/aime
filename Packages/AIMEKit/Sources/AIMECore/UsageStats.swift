public import Foundation

/// Opt-in features shared between the settings app and the input method
/// (`aime/features.json`). Read on launch and whenever `changedNotification` arrives.
public struct AIMEFeatures: Sendable, Codable, Equatable {
    /// Count committed words locally for the 高频词 dashboard. Off by default.
    public var usageStats = false
    /// ⌃⌥P rewrites the selected text with AI. Off by default.
    public var aiPolish = false
    /// "apple" (on-device) or "openai" (OpenAI-compatible endpoint, user key).
    public var aiProvider = "apple"
    public var aiBaseURL = "https://api.openai.com/v1"
    public var aiModel = "gpt-5-mini"
    /// Explicit consent to send the selected text to `aiBaseURL` when polishing.
    public var aiRemoteAllowed = false
    /// Small AIME button at the end of the candidate window (opens the quick menu).
    public var panelMenuButton = true
    /// Holding this modifier on its own opens the quick menu from the keyboard.
    public var menuHoldKey = ModifierHold.Key.option
    /// The user's own AI actions (name + prompt), listed in the quick menu after
    /// 润色 and 翻译.
    public var aiActions: [AIAction] = []
    /// 输入图层: committed text waits at the cursor (underlined) until Return, the
    /// auto-commit delay, or an action. Off by default.
    public var draftLayer = false
    /// Seconds of inactivity before a draft is committed automatically (0 = never).
    public var draftAutoCommit = 0
    /// Output Traditional Chinese by default (librime's `traditionalization` switch,
    /// applied to every new session; ⌃⇧4 still toggles it for the moment).
    public var traditional = false
    /// English punctuation by default (librime's `ascii_punct` switch). The state is
    /// shared by all apps: ⌃⇧3 in one app switches the others too (#10).
    public var asciiPunct = false

    public struct AIAction: Sendable, Codable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var prompt: String

        public init(id: UUID = UUID(), name: String, prompt: String) {
            self.id = id
            self.name = name
            self.prompt = prompt
        }
    }

    public init(usageStats: Bool = false) { self.usageStats = usageStats }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AIMEFeatures()
        usageStats = try container.decodeIfPresent(Bool.self, forKey: .usageStats) ?? defaults.usageStats
        aiPolish = try container.decodeIfPresent(Bool.self, forKey: .aiPolish) ?? defaults.aiPolish
        aiProvider = try container.decodeIfPresent(String.self, forKey: .aiProvider) ?? defaults.aiProvider
        aiBaseURL = try container.decodeIfPresent(String.self, forKey: .aiBaseURL) ?? defaults.aiBaseURL
        aiModel = try container.decodeIfPresent(String.self, forKey: .aiModel) ?? defaults.aiModel
        aiRemoteAllowed = try container.decodeIfPresent(Bool.self, forKey: .aiRemoteAllowed) ?? defaults.aiRemoteAllowed
        panelMenuButton = try container.decodeIfPresent(Bool.self, forKey: .panelMenuButton) ?? defaults.panelMenuButton
        menuHoldKey = try container.decodeIfPresent(ModifierHold.Key.self, forKey: .menuHoldKey) ?? defaults.menuHoldKey
        aiActions = try container.decodeIfPresent([AIAction].self, forKey: .aiActions) ?? defaults.aiActions
        draftLayer = try container.decodeIfPresent(Bool.self, forKey: .draftLayer) ?? defaults.draftLayer
        draftAutoCommit = try container.decodeIfPresent(Int.self, forKey: .draftAutoCommit) ?? defaults.draftAutoCommit
        traditional = try container.decodeIfPresent(Bool.self, forKey: .traditional) ?? defaults.traditional
        asciiPunct = try container.decodeIfPresent(Bool.self, forKey: .asciiPunct) ?? defaults.asciiPunct
    }

    public static let changedNotification = Notification.Name("app.zool.aime.features")

    static func url(_ paths: AIMEPaths) -> URL { paths.aimeDir.appendingPathComponent("features.json") }

    public static func load(_ paths: AIMEPaths) -> AIMEFeatures {
        guard let data = try? Data(contentsOf: url(paths)) else { return AIMEFeatures() }
        return (try? JSONDecoder().decode(AIMEFeatures.self, from: data)) ?? AIMEFeatures()
    }

    public func save(_ paths: AIMEPaths) throws {
        try FileManager.default.createDirectory(at: paths.aimeDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(paths), options: .atomic)
    }
}

/// Local word-frequency statistics. One small JSON file per day under
/// `~/Library/Application Support/AIME/Stats` (0700 directory, 0600 files, excluded
/// from backups), kept for `retentionDays`. Nothing here ever leaves the Mac.
public struct UsageStatsStore: Sendable {
    public static let retentionDays = 92
    /// Words that are never counted (password managers commit through other paths,
    /// but their windows are skipped anyway).
    public static let excludedApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "org.keepassxc.keepassxc",
    ]
    public static let clearedNotification = Notification.Name("app.zool.aime.stats.cleared")

    public let directory: URL

    public init(directory: URL = Self.defaultDirectory) { self.directory = directory }

    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AIME_STATS_DIR"] { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIME/Stats", isDirectory: true)
    }

    /// Only short Chinese words are worth counting: 2–8 Han characters, nothing else.
    public static func isCountable(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard (2...8).contains(scalars.count) else { return false }
        return scalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func fileURL(_ day: String) -> URL { directory.appendingPathComponent("\(day).json") }
    var blockedURL: URL { directory.appendingPathComponent("blocked.json") }

    public func counts(day: String) -> [String: Int] {
        guard let data = try? Data(contentsOf: fileURL(day)) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    /// Adds `delta` to the day's file. Called off the main thread by the recorder.
    public func merge(_ delta: [String: Int], into day: String) throws {
        guard !delta.isEmpty else { return }
        try prepareDirectory()
        let blocked = blockedWords()
        var counts = counts(day: day)
        for (word, count) in delta where !blocked.contains(word) { counts[word, default: 0] += count }
        try write(counts, to: fileURL(day))
    }

    public func days() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && $0 != "blocked.json" }.map { String($0.dropLast(5)) }.sorted()
    }

    /// Word totals and per-day totals for the last `days` days ending `now`.
    public func summary(days count: Int, now: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        var words: [String: Int] = [:]
        var daily: [UsageSummary.Day] = []
        let today = calendar.startOfDay(for: now)
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let dayCounts = counts(day: Self.dayKey(date, calendar: calendar))
            for (word, value) in dayCounts { words[word, default: 0] += value }
            daily.append(.init(date: date, total: dayCounts.values.reduce(0, +)))
        }
        let blocked = blockedWords()
        let top = words.filter { !blocked.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { UsageSummary.Word(text: $0.key, count: $0.value) }
        return UsageSummary(words: top, daily: daily)
    }

    public func blockedWords() -> Set<String> {
        guard let data = try? Data(contentsOf: blockedURL) else { return [] }
        return Set((try? JSONDecoder().decode([String].self, from: data)) ?? [])
    }

    /// Hides a word from the dashboard and removes its existing counts.
    public func block(_ word: String) throws {
        try prepareDirectory()
        var blocked = blockedWords()
        blocked.insert(word)
        try write(blocked.sorted(), to: blockedURL)
        for day in days() {
            var counts = counts(day: day)
            if counts.removeValue(forKey: word) != nil { try write(counts, to: fileURL(day)) }
        }
    }

    public func unblock(_ word: String) throws {
        var blocked = blockedWords()
        guard blocked.remove(word) != nil else { return }
        try write(blocked.sorted(), to: blockedURL)
    }

    /// Deletes files older than the retention window.
    public func prune(now: Date = Date(), calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: calendar.startOfDay(for: now)) else { return }
        let oldest = Self.dayKey(cutoff, calendar: calendar)
        for day in days() where day < oldest { try? FileManager.default.removeItem(at: fileURL(day)) }
    }

    /// Removes every count, word and activity alike (the block list is kept).
    public func clear() {
        for day in days() { try? FileManager.default.removeItem(at: fileURL(day)) }
        try? FileManager.default.removeItem(at: activityDirectory)
    }

    func prepareDirectory() throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: directory.path) else { return }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    func write(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct UsageSummary: Sendable, Equatable {
    public struct Word: Sendable, Equatable, Identifiable {
        public var text: String
        public var count: Int
        public var id: String { text }
    }

    public struct Day: Sendable, Equatable, Identifiable {
        public var date: Date
        public var total: Int
        public var id: Date { date }
    }

    public var words: [Word]
    public var daily: [Day]
    public var total: Int { daily.reduce(0) { $0 + $1.total } }
}

/// Main-thread side of the statistics: O(1) per commit into a bounded in-memory
/// buffer; `flush` hands the buffer to a background task that merges it into the
/// day's file.
@MainActor
public final class UsageRecorder {
    public static let maxPendingWords = 4096

    public var isEnabled = false {
        didSet { if !isEnabled { pending.removeAll(); pendingActivity = DayActivity(); generation += 1 } }
    }
    public private(set) var pending: [String: Int] = [:]
    /// Characters, commits, hours and apps since the last flush.
    public private(set) var pendingActivity = DayActivity()
    private var pendingDay: String?
    /// Bumped by `discard()`; queued flushes from an older generation are dropped.
    private var generation = 0
    private let store: UsageStatsStore
    private var writeChain: Task<Void, Never>?

    public init(store: UsageStatsStore = UsageStatsStore()) { self.store = store }

    /// Records one committed text. Cheap enough to call on every commit.
    public func record(_ text: String, app: String?, now: Date = Date()) {
        guard isEnabled else { return }
        if let app, UsageStatsStore.excludedApps.contains(app) { return }
        let counted = DayActivity.count(text)
        let countable = UsageStatsStore.isCountable(text)
        guard counted.han + counted.words > 0 || countable else { return }
        let day = UsageStatsStore.dayKey(now)
        if let pendingDay, pendingDay != day { flush() }
        pendingDay = day
        pendingActivity.add(han: counted.han, words: counted.words, hour: Calendar.current.component(.hour, from: now), app: app)
        guard countable else { return }
        if pending[text] == nil, pending.count >= Self.maxPendingWords { return }
        pending[text, default: 0] += 1
    }

    /// Drops everything not yet written (after the user clears statistics).
    public func discard() {
        pending.removeAll()
        pendingActivity = DayActivity()
        generation += 1
    }

    /// Clears after any in-flight write and before any subsequent flush. No disk
    /// work runs on the caller, and old queued deltas cannot restore cleared data.
    @discardableResult
    public func clear() -> Task<Void, Never> {
        discard()
        let store = store
        return enqueueWrite { store.clear() }
    }

    /// All recorder disk mutations share this sequence, including both counters
    /// and clear. The generation check belongs after the predecessor completes.
    @discardableResult
    func enqueueWrite(generation expected: Int? = nil, _ write: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        let previous = writeChain
        let task = Task.detached(priority: .utility) { [weak self] in
            await previous?.value
            if let expected {
                let current = await MainActor.run { self?.generation }
                guard current == expected else { return }
            }
            write()
        }
        writeChain = task
        return task
    }

    /// Writes the buffer in the background. Returns the task for tests.
    @discardableResult
    public func flush() -> Task<Void, Never>? {
        guard !pending.isEmpty || !pendingActivity.isEmpty, let day = pendingDay else { return nil }
        let delta = pending
        let activity = pendingActivity
        let started = generation
        pending.removeAll(keepingCapacity: true)
        pendingActivity = DayActivity()
        let store = store
        return enqueueWrite(generation: started) {
            try? store.merge(delta, into: day)
            try? store.mergeActivity(activity, into: day)
        }
    }
}
