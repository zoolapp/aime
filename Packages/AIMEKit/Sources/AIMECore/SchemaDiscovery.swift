public import Foundation

/// An input schema found in the user or shared data directory.
public struct SchemaInfo: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let author: String
    public let summary: String
    public let fromUserDir: Bool
}

public enum SchemaDiscovery {
    /// All `*.schema.yaml` in user + shared dirs (user copies shadow shared ones).
    public static func available(paths: AIMEPaths) -> [SchemaInfo] {
        var found: [String: SchemaInfo] = [:]
        let dirs = [(paths.sharedDataDir, false), (paths.userDataDir, true)]
        for (dir, isUser) in dirs {
            guard let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasSuffix(".schema.yaml") {
                guard let info = read(dir.appendingPathComponent(name), fromUserDir: isUser) else { continue }
                found[info.id] = info
            }
        }
        return found.values.sorted { $0.id < $1.id }
    }

    static func read(_ url: URL, fromUserDir: Bool) -> SchemaInfo? {
        // Only the leading `schema:` block matters; avoid parsing multi-MB files fully.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 16 * 1024)) ?? Data(), as: UTF8.self)
        var block: [String] = []
        var inSchema = false
        for line in head.components(separatedBy: .newlines) {
            if line.hasPrefix("schema:") { inSchema = true; block.append(line); continue }
            if inSchema {
                if let first = line.first, !first.isWhitespace, first != "#" { break }
                block.append(line)
            }
        }
        guard let schema = (try? ConfigValue.parse(yaml: block.joined(separator: "\n")))?["schema"],
              let id = schema["schema_id"]?.stringValue else { return nil }
        let authors = schema["author"]?.listValue?.compactMap(\.stringValue) ?? [schema["author"]?.stringValue].compactMap { $0 }
        return SchemaInfo(
            id: id,
            name: schema["name"]?.stringValue ?? id,
            author: authors.joined(separator: ", "),
            summary: (schema["description"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            fromUserDir: fromUserDir
        )
    }
}

extension SettingsStore {
    /// Writes a new `schema_list` into the generated default layer.
    public func setEnabledSchemas(_ ids: [String]) throws {
        let list = ConfigValue.list(ids.map { .map([.init("schema", .string($0))]) })
        try layers.setGenerated(.default, keypath: "schema_list", value: list)
    }

    /// `schema_list` including a pending (not yet deployed) change.
    public func pendingSchemas() -> [String] {
        let list = layers.generatedValue(.default, keypath: "schema_list") ?? built(.default)?.value(at: "schema_list")
        return (list?.listValue ?? []).compactMap { $0["schema"]?.stringValue }
    }

    // MARK: - App options

    public struct AppOption: Sendable, Hashable, Identifiable {
        public var bundleID: String
        /// Initial Chinese/English state of the app.
        public enum InitialMode: String, Sendable, Hashable, CaseIterable {
            /// No rule: the app follows the shared state.
            case shared
            case english
            case chinese
        }

        public var initialMode: InitialMode
        public var noInline: Bool
        public var vimMode: Bool
        public var id: String { bundleID }

        public init(bundleID: String, initialMode: InitialMode = .english, noInline: Bool = false, vimMode: Bool = false) {
            self.bundleID = bundleID
            self.initialMode = initialMode
            self.noInline = noInline
            self.vimMode = vimMode
        }

        var configValue: ConfigValue {
            var entries: [ConfigValue.Entry] = []
            switch initialMode {
            case .english: entries.append(.init("ascii_mode", true))
            case .chinese: entries.append(.init("ascii_mode", false))
            case .shared: break
            }
            if noInline { entries.append(.init("no_inline", true)) }
            if vimMode { entries.append(.init("vim_mode", true)) }
            return .map(entries)
        }
    }

    /// Effective app options: the frontend config as it will be after the pending edits
    /// (composed from the layers when nothing has been built yet).
    public func appOptions() -> [AppOption] {
        (previewFrontend()["app_options"]?.entries ?? []).compactMap { entry in
            guard entry.value.entries?.isEmpty == false else { return nil }
            return AppOption(
                bundleID: entry.key,
                initialMode: entry.value["ascii_mode"]?.boolValue.map { $0 ? .english : .chinese } ?? .shared,
                noInline: entry.value["no_inline"]?.boolValue ?? false,
                vimMode: entry.value["vim_mode"]?.boolValue ?? false
            )
        }
    }

    public func setAppOption(_ option: AppOption) throws {
        try layers.setGenerated(.frontend, keypath: "app_options/\(option.bundleID)", value: option.configValue)
    }

    /// Removing writes an empty map so options inherited from other layers are cleared too.
    public func removeAppOption(_ bundleID: String) throws {
        try layers.setGenerated(.frontend, keypath: "app_options/\(bundleID)", value: .map([]))
    }

    // MARK: - Sync directory (installation.yaml)

    var installationURL: URL { paths.userDataDir.appendingPathComponent("installation.yaml") }

    public func installationInfo() -> ConfigValue { (try? ConfigValue.load(contentsOf: installationURL)) ?? .map([]) }

    public var syncDir: String? { installationInfo()["sync_dir"]?.stringValue }

    /// Sets `sync_dir` in installation.yaml (nil = librime default `<user dir>/sync`).
    public func setSyncDir(_ path: String?) throws {
        var info = installationInfo()
        info.set(path.map(ConfigValue.string), at: "sync_dir")
        try info.yamlString().write(to: installationURL, atomically: true, encoding: .utf8)
    }
}

extension SettingsStore {
    /// The frontend config as it will look after the next deploy: the deployed
    /// `build/aime.yaml` (or the shipped `aime.yaml` before the first deploy) with pending
    /// generated edits applied. Drives the live appearance preview.
    public func previewFrontend() -> ConfigValue {
        var base: ConfigValue
        var pending = (try? layers.generatedPatch(.frontend)) ?? []
        if let built = built(.frontend) {
            base = built
        } else {
            base = paths.sharedDataDir.flatMap { try? ConfigValue.load(contentsOf: $0.appendingPathComponent("aime.yaml")) } ?? .map([])
            pending = (try? layers.composedPatch(.frontend)) ?? []
        }
        for entry in pending where !entry.key.hasSuffix("/+") {
            base.set(entry.value, at: entry.key.hasSuffix("/=") ? String(entry.key.dropLast(2)) : entry.key)
        }
        return base
    }
}
