public import Foundation

/// Imports an existing Rime user directory (normally Squirrel's `~/Library/Rime`) into
/// the AIME user directory.
///
/// The source directory is **never written to**: every operation reads from it and
/// writes under `AIMEPaths.userDataDir`. Copies use `FileManager.copyItem`, which clones
/// on APFS, so even large grammar models cost no extra disk space.
public struct SquirrelImporter: Sendable {
    public enum Action: Sendable, Equatable {
        /// Copy a file or directory as-is.
        case copy(String)
        /// Move a hand-written `*.custom.yaml` into the imported layer of `target`.
        case importCustom(String, ConfigTarget)
        /// Copy user dictionary snapshots so `sync_user_data` merges learned frequencies.
        case importSnapshots(String)
        case skip(String, reason: String)

        public var path: String {
            switch self {
            case let .copy(path), let .importCustom(path, _), let .importSnapshots(path), let .skip(path, _): path
            }
        }
    }

    public struct Plan: Sendable {
        public let source: URL
        public let actions: [Action]
        public var copies: [String] { actions.compactMap { if case let .copy(path) = $0 { path } else { nil } } }
        public var customs: [(String, ConfigTarget)] {
            actions.compactMap { if case let .importCustom(path, target) = $0 { (path, target) } else { nil } }
        }
    }

    public struct Report: Sendable, Codable {
        public var source: String
        public var importedAt: Date
        public var copied: [String]
        public var customLayers: [String]
        public var snapshots: [String]
        public var colorSchemesCarriedOver: [String]
        /// Things the user should know, e.g. learned frequencies that could not be migrated.
        public var warnings: [String] = []
    }

    public enum ImportError: Error, CustomStringConvertible {
        case sameDirectory
        case planMismatch

        public var description: String {
            switch self {
            case .sameDirectory: "导入源与 AIME 用户目录相同或互相包含，已拒绝"
            case .planMismatch: "导入计划与当前导入源不一致"
            }
        }
    }

    /// Entries that belong to the source installation and must not be carried over.
    static let skipped: [String: String] = [
        "build": "compiled output; AIME rebuilds it",
        "installation.yaml": "per-installation identity",
        "user.yaml": "per-installation state",
        "squirrel.yaml": "Squirrel frontend defaults; AIME ships aime.yaml",
        "weasel.yaml": "Windows frontend",
        "weasel.custom.yaml": "Windows frontend",
        "trash": "librime trash folder",
        ".git": "version control metadata",
        ".DS_Store": "Finder metadata",
    ]

    static let nonConfigNames: Set<String> = ["README", "LICENSE", "go.work", "go.work.sum", "Makefile", "others", "node_modules", "package.json"]

    public let paths: AIMEPaths
    public let source: URL

    public init(paths: AIMEPaths, source: URL = AIMEPaths.squirrelUserDir) {
        self.paths = paths
        self.source = source
    }

    public func plan() throws -> Plan {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: source.path).sorted()
        let actions: [Action] = names.map { name in
            if let reason = Self.skipped[name] { return .skip(name, reason: reason) }
            // Hidden entries (.git, .specstory, .vscode…) and repository files are not
            // part of a Rime configuration and may hold unrelated private data.
            if name.hasPrefix(".") { return .skip(name, reason: "hidden file or folder, not Rime data") }
            if Self.nonConfigNames.contains(name) || name.hasSuffix(".md") {
                return .skip(name, reason: "repository file, not Rime data")
            }
            if name.hasSuffix(".userdb") { return .skip(name, reason: "live LevelDB; merged through sync snapshots instead") }
            if name == "sync" { return .importSnapshots(name) }
            if name.hasSuffix(".custom.yaml") {
                let base = String(name.dropLast(".custom.yaml".count))
                let target: ConfigTarget = switch base {
                case "default": .default
                case "squirrel": .frontend
                default: .schema(base)
                }
                return .importCustom(name, target)
            }
            return .copy(name)
        }
        return Plan(source: source, actions: actions)
    }

    @discardableResult
    public func execute(_ plan: Plan) throws -> Report {
        let fm = FileManager.default
        guard plan.source.standardizedFileURL == source.standardizedFileURL else { throw ImportError.planMismatch }
        let from = source.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let to = paths.userDataDir.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard !from.hasPrefix(to), !to.hasPrefix(from) else { throw ImportError.sameDirectory }
        let layers = ConfigLayers(paths: paths)
        try fm.createDirectory(at: paths.userDataDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.importedDir, withIntermediateDirectories: true)

        var report = Report(
            source: source.path, importedAt: Date(), copied: [], customLayers: [], snapshots: [], colorSchemesCarriedOver: []
        )

        for action in plan.actions {
            switch action {
            case let .copy(name):
                let incoming = source.appendingPathComponent(name)
                let destination = paths.userDataDir.appendingPathComponent(name)
                // Phrase tables may have been edited in AIME since the last import:
                // merge instead of overwriting so nothing added there is lost.
                if fm.fileExists(atPath: destination.path), CustomPhrases.looksLikeTable(incoming),
                   !fm.contentsEqual(atPath: destination.path, andPath: incoming.path) {
                    var merged = CustomPhrases.load(from: destination)
                    let result = merged.merge(CustomPhrases.load(from: incoming))
                    if result.added > 0 { try merged.save(to: destination) }
                    report.copied.append("\(name) (merged +\(result.added))")
                } else {
                    try Self.replace(destination, withCopyOf: incoming)
                    report.copied.append(name)
                }

            case let .importCustom(name, target):
                let imported = layers.importedURL(target)
                let incoming = source.appendingPathComponent(name)
                // Keep a copy of a previous imported layer (it may carry edits made in AIME).
                if fm.fileExists(atPath: imported.path), !fm.contentsEqual(atPath: imported.path, andPath: incoming.path) {
                    try layers.backup(imported)
                }
                try Self.replace(imported, withCopyOf: incoming)
                try layers.installShim(target)
                layers.invalidateBuild(target)
                report.customLayers.append("\(name) → \(imported.path.replacingOccurrences(of: paths.userDataDir.path + "/", with: ""))")

            case let .importSnapshots(name):
                report.snapshots += try importSnapshots(from: source.appendingPathComponent(name))

            case .skip:
                continue
            }
        }

        report.colorSchemesCarriedOver = try carryOverColorSchemes(layers: layers)
        if plan.actions.contains(where: { if case .importSnapshots = $0 { true } else { false } }), report.snapshots.isEmpty {
            report.warnings.append("未找到词频快照（sync/*/*.userdb.txt）：请先在鼠须管中执行「同步用户数据」再导入，否则学习到的词频不会迁移。")
        } else if !plan.actions.contains(where: { if case .importSnapshots = $0 { true } else { false } }) {
            report.warnings.append("导入源没有 sync 目录，学习到的词频不会迁移。")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: paths.aimeDir.appendingPathComponent("import-report.json"))
        return report
    }

    /// Copies to a temporary sibling first, then swaps it in, so a failed copy never
    /// leaves the destination deleted.
    static func replace(_ destination: URL, withCopyOf source: URL) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".aime-\(UUID().uuidString)-\(destination.lastPathComponent)")
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: staging)
        do {
            if fm.fileExists(atPath: destination.path) {
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: destination.path, isDirectory: &isDirectory)
                if isDirectory.boolValue {
                    let old = destination.deletingLastPathComponent().appendingPathComponent(".aime-old-\(UUID().uuidString)")
                    try fm.moveItem(at: destination, to: old)
                    try fm.moveItem(at: staging, to: destination)
                    try? fm.removeItem(at: old)
                } else {
                    _ = try fm.replaceItemAt(destination, withItemAt: staging)
                }
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Copies `<sync>/<installation>/*.userdb.txt` into AIME's sync dir under the source
    /// installation id. librime's `sync_user_data` then merges them into AIME's userdb.
    private func importSnapshots(from syncDir: URL) throws -> [String] {
        let fm = FileManager.default
        var imported: [String] = []
        let installations = (try? fm.contentsOfDirectory(atPath: syncDir.path)) ?? []
        for installation in installations.sorted() {
            let folder = syncDir.appendingPathComponent(installation)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let snapshots = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".userdb.txt") }
            guard !snapshots.isEmpty else { continue }
            let destination = paths.userDataDir.appendingPathComponent("sync/\(installation)", isDirectory: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for snapshot in snapshots.sorted() {
                try Self.replace(destination.appendingPathComponent(snapshot), withCopyOf: folder.appendingPathComponent(snapshot))
                imported.append("\(installation)/\(snapshot)")
            }
        }
        return imported
    }

    /// Color schemes the imported frontend patch refers to but only the source's
    /// `squirrel.yaml` defines are copied into the generated frontend layer.
    private func carryOverColorSchemes(layers: ConfigLayers) throws -> [String] {
        let importedFrontend = layers.importedURL(.frontend)
        guard let patch = (try? ConfigValue.load(contentsOf: importedFrontend))?["patch"] else { return [] }
        let referenced = ["style/color_scheme", "style/color_scheme_dark"].compactMap { key in
            patch[key]?.stringValue ?? patch.value(at: key)?.stringValue
        }
        let definedInPatch = Set((patch["preset_color_schemes"]?.entries ?? []).map(\.key)
            + (patch.entries ?? []).compactMap { entry in
                entry.key.hasPrefix("preset_color_schemes/") ? String(entry.key.dropFirst("preset_color_schemes/".count)) : nil
            })
        let missing = referenced.filter { !definedInPatch.contains($0) }
        guard !missing.isEmpty,
              let squirrel = try? ConfigValue.load(contentsOf: source.appendingPathComponent("squirrel.yaml")),
              let presets = squirrel["preset_color_schemes"]
        else { return [] }

        var carried: [String] = []
        try layers.updateGenerated(.frontend) { generated in
            for name in missing {
                guard let scheme = presets[name] else { continue }
                let key = "preset_color_schemes/\(name)"
                generated.removeAll { $0.key == key }
                generated.append(.init(key, scheme))
                carried.append(name)
            }
        }
        return carried
    }
}
