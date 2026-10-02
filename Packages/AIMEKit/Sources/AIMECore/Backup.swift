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
        /// Version 2 records whole-layer replacement even when a layer has no files.
        /// Absent in version 1, whose missing layers must remain untouched.
        public var directories: [String]? = nil

        public var settingsCount: Int { files.keys.filter { $0.hasPrefix("rime/aime/") }.count }
        public var phraseCount: Int { files.keys.filter { $0.hasPrefix("rime/") && $0.hasSuffix(".txt") && $0.contains("custom_phrase") }.count }
        public var frequencyCount: Int { files.keys.filter { $0.hasSuffix(".userdb.txt") }.count }
        public var statsCount: Int { files.keys.filter { $0.hasPrefix("stats/") }.count }
    }

    public enum BackupError: Error, CustomStringConvertible {
        case notABackup
        case damaged(String)
        case archiveFailed(String)
        case unsafePath(String)
        case resourceLimit
        case rollbackFailed(String)

        public var description: String {
            switch self {
            case .notABackup: "这不是艾么输入法的备份文件"
            case let .damaged(file): "备份文件已损坏（\(file) 校验不一致），未做任何改动"
            case let .archiveFailed(detail): "压缩或解压失败：\(detail)"
            case let .unsafePath(path): "备份包含不安全的文件或恢复路径：\(path)"
            case .resourceLimit: "备份超过限制（最多 20000 个成员、展开后最多 512 MB）"
            case let .rollbackFailed(path): "恢复失败且未能完全回滚，恢复前的文件保留在：\(path)"
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
    static let maximumMembers = 20_000
    static let maximumExpandedBytes: UInt64 = 512 * 1024 * 1024
    static let replacementDirectories = ["rime/aime/generated", "rime/aime/imported", "rime/aime/subscriptions"]

    /// Files to back up, as (path inside the archive, source file).
    public func plan(includeStats: Bool) -> [(String, URL)] {
        let fm = FileManager.default
        var result: [(String, URL)] = []
        func addTree(_ source: URL, as prefix: String) {
            let type = (try? fm.attributesOfItem(atPath: source.path))?[.type] as? FileAttributeType
            if type == .typeRegular { result.append((prefix, source)); return }
            guard type == .typeDirectory else { return } // Never follow links into other workspaces.
            let items = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !item.lastPathComponent.hasPrefix(".") {
                addTree(item, as: prefix + "/" + item.lastPathComponent)
            }
        }
        if (try? fm.attributesOfItem(atPath: paths.aimeDir.path))?[.type] as? FileAttributeType == .typeDirectory {
            for entry in Self.aimeEntries { addTree(paths.aimeDir.appendingPathComponent(entry), as: "rime/aime/" + entry) }
        }

        // The user's own RIME files at the top level: phrase tables, schemas, dictionaries,
        // Lua and OpenCC folders, extra dictionary folders. Composed `*.custom.yaml`
        // files are left out (AIME regenerates them from the layers above).
        let root = (try? fm.contentsOfDirectory(at: paths.userDataDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in root.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = item.lastPathComponent
            guard !name.hasPrefix("."), !Self.excludedRootDirectories.contains(name) else { continue }
            let type = (try? fm.attributesOfItem(atPath: item.path))?[.type] as? FileAttributeType
            if type == .typeDirectory {
                guard !name.hasSuffix(".userdb") else { continue } // live LevelDB: snapshots below instead
                addTree(item, as: "rime/" + name)
            } else if type == .typeRegular && Self.isRootFile(name) {
                result.append(("rime/" + name, item))
            }
        }

        // Learned frequencies: the RIME sync snapshots (`*.userdb.txt`) of every device.
        let sync = paths.userDataDir.appendingPathComponent("sync")
        let syncType = (try? fm.attributesOfItem(atPath: sync.path))?[.type] as? FileAttributeType
        for device in syncType == .typeDirectory ? ((try? fm.contentsOfDirectory(at: sync, includingPropertiesForKeys: nil)) ?? []) : [] {
            guard (try? fm.attributesOfItem(atPath: device.path))?[.type] as? FileAttributeType == .typeDirectory else { continue }
            for file in (try? fm.contentsOfDirectory(at: device, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasSuffix(".userdb.txt") {
                guard (try? fm.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType == .typeRegular else { continue }
                result.append(("rime/sync/\(device.lastPathComponent)/\(file.lastPathComponent)", file))
            }
        }
        if includeStats { addTree(statsDirectory, as: "stats") }
        return result.filter { Self.isAllowedFile($0.0) }
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
        let manifest = Manifest(format: Self.format, version: 2, created: now, appVersion: appVersion,
                                includesStats: includeStats, files: files, directories: Self.replacementDirectories)
        for directory in Self.replacementDirectories {
            try fm.createDirectory(at: content.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
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
            try Self.validateTree(staging)
            let content = staging.appendingPathComponent("AIME Backup")
            guard let data = try? Data(contentsOf: content.appendingPathComponent("manifest.json")),
                  let manifest = try? Self.decoder.decode(Manifest.self, from: data), manifest.format == Self.format,
                  (1...2).contains(manifest.version) else {
                throw BackupError.notABackup
            }
            if manifest.version >= 2 {
                guard let directories = manifest.directories,
                      directories.count == Self.replacementDirectories.count,
                      Set(directories) == Set(Self.replacementDirectories) else { throw BackupError.notABackup }
                for directory in directories {
                    guard (try? fm.attributesOfItem(atPath: content.appendingPathComponent(directory).path))?[.type] as? FileAttributeType == .typeDirectory
                    else { throw BackupError.unsafePath(directory) }
                }
            }
            for (relative, digest) in manifest.files {
                guard Self.isAllowedFile(relative),
                      (try? fm.attributesOfItem(atPath: content.appendingPathComponent(relative).path))?[.type] as? FileAttributeType == .typeRegular
                else { throw BackupError.unsafePath(relative) }
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
        try Self.validateTree(opened.staging)
        // Check every destination before making even the safety copy or deleting a layer.
        let targets = try opened.manifest.files.keys.sorted().map { relative in
            (relative, try restoreTarget(relative))
        }
        let directories = Self.replacementDirectories.filter { directory in
            opened.manifest.version >= 2 || opened.manifest.files.keys.contains { $0.hasPrefix(directory + "/") }
        }
        let layers = directories.map { paths.userDataDir.appendingPathComponent(String($0.dropFirst("rime/".count))) }
        for layer in layers {
            try validateTarget(layer, inside: paths.userDataDir)
        }
        try fm.createDirectory(at: safetyDirectory, withIntermediateDirectories: true)
        let stamp = Self.stamp(now)
        let safety = safetyDirectory.appendingPathComponent("恢复前自动备份 \(stamp).\(Self.fileExtension)")
        try create(at: safety, includeStats: opened.manifest.includesStats, now: now)

        // Keep the public safety archive above. A move journal additionally preserves
        // exact replaced items (including hidden files, empty folders and metadata),
        // and records absent targets so rollback removes newly introduced files too.
        let rollback = safetyDirectory.appendingPathComponent(".restore-\(UUID().uuidString)")
        try fm.createDirectory(at: rollback, withIntermediateDirectories: true)
        var keepRollback = false
        defer { if !keepRollback { try? fm.removeItem(at: rollback) } }
        var originals: [(target: URL, root: URL, saved: URL?)] = []
        var createdParents: [URL] = []
        func preserve(_ target: URL, inside root: URL) throws {
            try validateTarget(target, inside: root)
            var saved: URL?
            if fm.fileExists(atPath: target.path) {
                let copy = rollback.appendingPathComponent(String(originals.count))
                try fm.moveItem(at: target, to: copy)
                saved = copy
            }
            originals.append((target, root, saved))
        }
        func createParents(of target: URL) throws {
            var missing: [URL] = []
            var parent = target.deletingLastPathComponent()
            while !fm.fileExists(atPath: parent.path) {
                missing.append(parent)
                parent.deleteLastPathComponent()
            }
            for directory in missing.reversed() {
                try fm.createDirectory(at: directory, withIntermediateDirectories: false)
                // Contents of a replaced layer are already covered by its journal entry.
                if !layers.contains(where: { directory.path == $0.path || directory.path.hasPrefix($0.path + "/") }) {
                    createdParents.append(directory)
                }
            }
        }
        do {
            for layer in layers {
                try preserve(layer, inside: paths.userDataDir)
                try createParents(of: layer)
                try fm.createDirectory(at: layer, withIntermediateDirectories: false)
            }
            for (relative, target) in targets {
                _ = try restoreTarget(relative)
                if !directories.contains(where: { relative.hasPrefix($0 + "/") }) {
                    try preserve(target, inside: relative.hasPrefix("stats/") ? statsDirectory : paths.userDataDir)
                }
                try createParents(of: target)
                try fm.copyItem(at: opened.content.appendingPathComponent(relative), to: target)
            }
        } catch {
            for original in originals.reversed() {
                do {
                    try validateTarget(original.target, inside: original.root)
                    if fm.fileExists(atPath: original.target.path) { try fm.removeItem(at: original.target) }
                    if let saved = original.saved { try fm.moveItem(at: saved, to: original.target) }
                } catch { keepRollback = true }
            }
            for directory in createdParents.reversed() {
                do {
                    if try fm.contentsOfDirectory(atPath: directory.path).isEmpty { try fm.removeItem(at: directory) }
                } catch { keepRollback = true }
            }
            if keepRollback { throw BackupError.rollbackFailed(rollback.path) }
            throw error
        }
        return safety
    }

    /// Discards an opened backup without restoring it.
    public func close(_ opened: Opened) { try? FileManager.default.removeItem(at: opened.staging) }

    public static func suggestedName(now: Date = Date()) -> String { "艾么输入法备份 \(stamp(now)).\(fileExtension)" }

    // MARK: - Helpers

    static func isRootFile(_ name: String) -> Bool {
        name.hasSuffix(".schema.yaml") || name.hasSuffix(".dict.yaml") || name.hasSuffix(".lua")
            || name.hasSuffix(".txt") && name.contains("custom_phrase")
    }

    static func isAllowedFile(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts.contains(where: {
            let name = $0.lowercased()
            return name.isEmpty || name.hasPrefix(".") || name.contains("\\") || name.contains("\0")
                || name == "build" || name.hasSuffix(".userdb") || name == "lock" || name.hasSuffix(".lock")
        }) else { return false }
        if parts[0] == "stats" { return true }
        guard parts[0] == "rime" else { return false }
        if parts[1] == "aime" {
            guard parts.count >= 3, aimeEntries.contains(parts[2]) else { return false }
            return ["generated", "imported", "subscriptions", "packages"].contains(parts[2]) ? parts.count >= 4 : parts.count == 3
        }
        if parts[1] == "sync" { return parts.count == 4 && parts[3].hasSuffix(".userdb.txt") }
        guard !excludedRootDirectories.contains(parts[1]) else { return false }
        return parts.count > 2 || isRootFile(parts[1])
    }

    /// Inspect all extracted members, including ones omitted from the manifest, without
    /// following symlinks. Count directories too; only directories and regular files exist
    /// in a backup, and only regular files may be restored.
    static func validateTree(_ root: URL, maximumMembers: Int = maximumMembers,
                             maximumBytes: UInt64 = maximumExpandedBytes) throws {
        let fm = FileManager.default
        guard try fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw BackupError.unsafePath(root.lastPathComponent)
        }
        var pending = [root]
        var members = 0
        var bytes: UInt64 = 0
        while let directory = pending.popLast() {
            for item in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                members += 1
                guard members <= maximumMembers else { throw BackupError.resourceLimit }
                let attributes = try fm.attributesOfItem(atPath: item.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory: pending.append(item)
                case .typeRegular:
                    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    guard size <= maximumBytes - bytes else { throw BackupError.resourceLimit }
                    bytes += size
                default: throw BackupError.unsafePath(item.lastPathComponent)
                }
            }
        }
    }

    func restoreTarget(_ relative: String) throws -> URL {
        guard Self.isAllowedFile(relative) else { throw BackupError.unsafePath(relative) }
        let isStats = relative.hasPrefix("stats/")
        let root = isStats ? statsDirectory : paths.userDataDir
        let target = root.appendingPathComponent(String(relative.dropFirst(isStats ? 6 : 5)))
        try validateTarget(target, inside: root)
        return target
    }

    func validateTarget(_ target: URL, inside root: URL) throws {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard parent == base || parent.hasPrefix(base + "/") else { throw BackupError.unsafePath(target.path) }
        // Also reject in-workspace aliases (e.g. a link to build/ or a live userdb),
        // dangling links and linked leaves. No path component below the trusted root
        // should redirect a write, deletion or safety snapshot.
        var component = target.standardizedFileURL
        let lexicalRoot = root.standardizedFileURL.path
        guard component.path.hasPrefix(lexicalRoot + "/") else { throw BackupError.unsafePath(target.path) }
        while component.path != lexicalRoot {
            if (try? FileManager.default.attributesOfItem(atPath: component.path))?[.type] as? FileAttributeType == .typeSymbolicLink {
                throw BackupError.unsafePath(target.path)
            }
            component.deleteLastPathComponent()
        }
    }

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
