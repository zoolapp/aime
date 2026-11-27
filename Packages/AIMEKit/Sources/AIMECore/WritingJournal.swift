public import Foundation

/// Opt-in local record of what was written through the draft layer and of AI actions
/// (the text, and the result that was chosen), for the user's own later study of how
/// they write. One JSON Lines file per day under
/// `~/Library/Application Support/AIME/Journal` (0700 directory, 0600 files, excluded
/// from backups). Off by default; nothing here ever leaves the Mac unless exported.
public struct WritingJournal: Sendable {
    public struct Entry: Sendable, Codable, Equatable {
        public enum Kind: String, Sendable, Codable { case typed, action }
        public var time: Date
        public var app: String
        public var kind: Kind
        /// What was typed.
        public var text: String
        /// For an action: its name and the result that was applied.
        public var action: String?
        public var result: String?

        public init(time: Date = Date(), app: String, kind: Kind, text: String, action: String? = nil, result: String? = nil) {
            self.time = time
            self.app = app
            self.kind = kind
            self.text = text
            self.action = action
            self.result = result
        }
    }

    public let directory: URL
    /// Writes happen here, in order, off the key path.
    private static let queue = DispatchQueue(label: "app.zool.aime.journal", qos: .utility)

    public init(directory: URL = Self.defaultDirectory) { self.directory = directory }

    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AIME_JOURNAL_DIR"] { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIME/Journal", isDirectory: true)
    }

    /// Whether text written in `app` may be recorded: never in password managers, and
    /// never text that is only whitespace.
    public static func accepts(app: String, text: String) -> Bool {
        !UsageStatsStore.excludedApps.contains(app) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func fileURL(_ day: String) -> URL { directory.appendingPathComponent("\(day).jsonl") }

    /// Queues the entry; returns at once.
    public func record(_ entry: Entry) {
        guard Self.accepts(app: entry.app, text: entry.text) else { return }
        Self.queue.async { try? append(entry) }
    }

    /// Waits for queued entries to be on disk (export, tests).
    public func flush() { Self.queue.sync {} }

    func append(_ entry: Entry) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var line = try Self.encoder().encode(entry)
        line.append(0x0A)
        let url = fileURL(UsageStatsStore.dayKey(entry.time))
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            manager.createFile(atPath: url.path, contents: line, attributes: [.posixPermissions: 0o600])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = url
            try? target.setResourceValues(values)
        }
    }

    private var files: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Every recorded entry, oldest first. Lines that do not parse are skipped.
    public func entries() -> [Entry] {
        flush()
        let decoder = Self.decoder()
        return files.flatMap { url -> [Entry] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
        }
    }

    public var count: Int { entries().count }

    /// Writes everything to one JSON Lines file (private to the user) at `url`.
    public func export(to url: URL) throws {
        let encoder = Self.encoder()
        var data = Data()
        for entry in entries() {
            data.append(try encoder.encode(entry))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Removes every recorded entry.
    public func clear() {
        flush()
        for url in files { try? FileManager.default.removeItem(at: url) }
    }
}
