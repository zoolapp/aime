public import Foundation

/// Local backup and restore of everything the user made: settings layers, feature
/// switches, snippets and phrase tables, vocabulary subscriptions, their own schemas,
/// dictionaries and Lua, the learned frequencies (as RIME sync snapshots) and, if asked,
/// input statistics. One `.aimebackup` file (a zip with a manifest and SHA-256 per file);
/// nothing leaves the Mac. Left out: what AIME rebuilds or ships (build output, the
/// bundled rime-ice dictionaries, the grammar model, caches) and the API key.
public struct BackupManager: Sendable {
    public static let fileExtension = "aimebackup"
    public static let format = "aime-backup"

    public struct Manifest: Sendable, Codable, Equatable {
        public var format: String
        public var version: Int
        public var created: Date
        public var appVersion: String?
        public var includesStats: Bool
        /// Relative path inside the archive (`rime/…` or `stats/…`) → SHA-256.
        public var files: [String: String]

        public var settingsCount: Int { files.keys.filter { $0.hasPrefix("rime/aime/") }.count }
        public var phraseCount: Int { files.keys.filter { $0.hasPrefix("rime/") && $0.hasSuffix(".txt") && $0.contains("custom_phrase") }.count }
        public var frequencyCount: Int { files.keys.filter { $0.hasSuffix(".userdb.txt") }.count }
        public var statsCount: Int { files.keys.filter { $0.hasPrefix("stats/") }.count }
    }

    public enum BackupError: Error, CustomStringConvertible {
        case notABackup
        case damaged(String)
        case archiveFailed(String)

        public var description: String {
            switch self {
            case .notABackup: "这不是艾么输入法的备份文件"
            case let .damaged(file): "备份文件已损坏（\(file) 校验不一致），未做任何改动"
            case let .archiveFailed(detail): "压缩或解压失败：\(detail)"
            }
        }
    }

    public let paths: AIMEPaths
    public let statsDirectory: URL
    /// Where safety copies made before a restore go.
    public let safetyDirectory: URL

    public init(paths: AIMEPaths, statsDirectory: URL = UsageStatsStore.defaultDirectory, safetyDirectory: URL? = nil) {
        self.paths = paths
        self.statsDirectory = statsDirectory
        self.safetyDirectory = safetyDirectory ?? paths.userDataDir.deletingLastPathComponent().appendingPathComponent("Backups")
    }

    // MARK: - What is included

    /// Directories under `aime/` that are the user's own state.
    static let aimeEntries = ["generated", "imported", "subscriptions", "packages",
                              "features.json", "snippets.json", "subscriptions.json", "app-recommendations.json"]
    /// Root directories AIME ships or rebuilds (never backed up).
    static let excludedRootDirectories: Set<String> = ["aime", "build", "sync", "trash", "cn_dicts", "en_dicts"]

    /// Files to back up, as (path inside the archive, source file).
    public func plan(includeStats: Bool) -> [(String, URL)] {
        let fm = FileManager.default
        var result: [(String, URL)] = []
        func addTree(_ source: URL, as prefix: String) {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return }
            if !isDirectory.boolValue { result.append((prefix, source)); return }
            let items = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !item.lastPathComponent.hasPrefix(".") {
                addTree(item, as: prefix + "/" + item.lastPathComponent)
            }
        }
        for entry in Self.aimeEntries { addTree(paths.aimeDir.appendingPathComponent(entry), as: "rime/aime/" + entry) }

        // The user's own RIME files at the top level: phrase tables, schemas, dictionaries,
        // Lua and OpenCC folders, extra dictionary folders. Composed `*.custom.yaml`
        // files are left out (AIME regenerates them from the layers above).
        let root = (try? fm.contentsOfDirectory(at: paths.userDataDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in root.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = item.lastPathComponent
            guard !name.hasPrefix("."), !Self.excludedRootDirectories.contains(name) else { continue }
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                guard !name.hasSuffix(".userdb") else { continue } // live LevelDB: snapshots below instead
                addTree(item, as: "rime/" + name)
            } else if name.hasSuffix(".schema.yaml") || name.hasSuffix(".dict.yaml") || name.hasSuffix(".txt") && name.contains("custom_phrase")
                        || name.hasSuffix(".lua") {
                result.append(("rime/" + name, item))
            }
        }

        // Learned frequencies: the RIME sync snapshots (`*.userdb.txt`) of every device.
        let sync = paths.userDataDir.appendingPathComponent("sync")
        for device in (try? fm.contentsOfDirectory(at: sync, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: device, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasSuffix(".userdb.txt") {
                result.append(("rime/sync/\(device.lastPathComponent)/\(file.lastPathComponent)", file))
            }
        }
        if includeStats { addTree(statsDirectory, as: "stats") }
        return result
    }

    // MARK: - Backup

    /// Writes a backup to `destination` (overwriting it). Returns its manifest.
    @discardableResult
    public func create(at destination: URL, includeStats: Bool, appVersion: String? = nil, now: Date = Date()) throws -> Manifest {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("aime-backup-\(UUID().uuidString)")
        let content = staging.appendingPathComponent("AIME Backup")
        defer { try? fm.removeItem(at: staging) }
        var files: [String: String] = [:]
        for (relative, source) in plan(includeStats: includeStats) {
            let target = content.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
            files[relative] = try PackageManager.sha256(of: target)
        }
        let manifest = Manifest(format: Self.format, version: 1, created: now, appVersion: appVersion, includesStats: includeStats, files: files)
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
        try Self.encoder.encode(manifest).write(to: content.appendingPathComponent("manifest.json"))
        try? fm.removeItem(at: destination)
        try Self.ditto(["-c", "-k", "--sequesterRsrc", "--keepParent", content.path, destination.path])
        return manifest
    }

    // MARK: - Restore

    /// A backup unpacked and verified, ready to restore.
    public struct Opened: Sendable {
        public let manifest: Manifest
        let content: URL
        let staging: URL
    }

    /// Unpacks and verifies a backup without touching the current configuration.
    public func open(_ archive: URL) throws -> Opened {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("aime-restore-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try Self.ditto(["-x", "-k", archive.path, staging.path])
            let content = staging.appendingPathComponent("AIME Backup")
            guard let data = try? Data(contentsOf: content.appendingPathComponent("manifest.json")),
                  let manifest = try? Self.decoder.decode(Manifest.self, from: data), manifest.format == Self.format else {
                throw BackupError.notABackup
            }
            for (relative, digest) in manifest.files {
                // Only the two known roots, and no way out of them.
                guard relative.hasPrefix("rime/") || relative.hasPrefix("stats/"), !relative.split(separator: "/").contains("..") else {
                    throw BackupError.damaged(relative)
                }
                guard (try? PackageManager.sha256(of: content.appendingPathComponent(relative))) == digest else { throw BackupError.damaged(relative) }
            }
            return Opened(manifest: manifest, content: content, staging: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Restores an opened backup. The current state is saved first to `safetyDirectory`
    /// (returned), so a restore can itself be undone.
    @discardableResult
    public func restore(_ opened: Opened, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: opened.staging) }
        try fm.createDirectory(at: safetyDirectory, withIntermediateDirectories: true)
        let stamp = Self.stamp(now)
        let safety = safetyDirectory.appendingPathComponent("恢复前自动备份 \(stamp).\(Self.fileExtension)")
        try create(at: safety, includeStats: opened.manifest.includesStats, now: now)

        // Settings layers are replaced as a whole, so nothing from the old state lingers.
        for directory in ["generated", "imported", "subscriptions"] {
            let target = paths.aimeDir.appendingPathComponent(directory)
            if opened.manifest.files.keys.contains(where: { $0.hasPrefix("rime/aime/\(directory)/") }) { try? fm.removeItem(at: target) }
        }
        for relative in opened.manifest.files.keys.sorted() {
            let source = opened.content.appendingPathComponent(relative)
            let target: URL
            if relative.hasPrefix("stats/") {
                target = statsDirectory.appendingPathComponent(String(relative.dropFirst("stats/".count)))
            } else {
                target = paths.userDataDir.appendingPathComponent(String(relative.dropFirst("rime/".count)))
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: source, to: target)
        }
        return safety
    }

    /// Discards an opened backup without restoring it.
    public func close(_ opened: Opened) { try? FileManager.default.removeItem(at: opened.staging) }

    public static func suggestedName(now: Date = Date()) -> String { "艾么输入法备份 \(stamp(now)).\(fileExtension)" }

    // MARK: - Helpers

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Zip and unzip with the system's `ditto` (keeps Chinese file names, no dependency).
    static func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BackupError.archiveFailed(String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }
}
