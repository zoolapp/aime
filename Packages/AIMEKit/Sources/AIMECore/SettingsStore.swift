public import Foundation

/// Reads effective values from the deployed `build/` output and writes changes into
/// the generated layer. Does not link librime; deployment is requested separately.
public struct SettingsStore: Sendable {
    public let paths: AIMEPaths
    public let layers: ConfigLayers
    public let catalog: SettingCatalog

    public init(paths: AIMEPaths, catalog: SettingCatalog = .bundled) {
        self.paths = paths
        self.layers = ConfigLayers(paths: paths)
        self.catalog = catalog
    }

    // MARK: - Reading

    /// The merged config librime produced for `target`, or nil before the first deploy.
    public func built(_ target: ConfigTarget) -> ConfigValue? {
        try? ConfigValue.load(contentsOf: paths.builtConfig(target.configID))
    }

    /// Schemas enabled in `schema_list`, in order.
    public func enabledSchemas() -> [String] {
        (built(.default)?.value(at: "schema_list")?.listValue ?? []).compactMap { $0["schema"]?.stringValue }
    }

    /// The first enabled schema is what the catalog's `schema`-file settings target.
    public func primarySchema() -> String? { enabledSchemas().first }

    /// Effective value: pending generated value, else deployed value, else catalog default.
    public func value(for setting: SettingCatalog.Setting, schemaID: String? = nil) -> ConfigValue? {
        guard let target = setting.target(schemaID: schemaID ?? primarySchema()) else { return setting.default }
        if let items = setting.listItems {
            let current = list(target: target, keypath: setting.keypath)
            return .bool(items.allSatisfy(current.contains))
        }
        guard let keypath = resolve(setting.keypath, target: target) else { return setting.default }
        if let pending = layers.generatedValue(target, keypath: keypath) { return pending }
        if let value = built(target)?.value(at: keypath) { return value }
        // `style/aime/<key>` not set yet: show what is in effect from the plain style
        // (e.g. an imported Squirrel style) rather than the catalog default.
        if keypath.hasPrefix("style/aime/"),
           let inherited = previewFrontend().value(at: "style/" + keypath.dropFirst("style/aime/".count)) {
            return inherited
        }
        return setting.default
    }

    /// Current value of a list node, preferring a pending generated replacement.
    public func list(target: ConfigTarget, keypath: String) -> [ConfigValue] {
        (layers.generatedValue(target, keypath: keypath) ?? built(target)?.value(at: keypath))?.listValue ?? []
    }

    /// Current `speller/algebra`.
    public func algebra(target: ConfigTarget) -> [String] {
        list(target: target, keypath: "speller/algebra").compactMap(\.stringValue)
    }

    /// Replaces `@field=value` selectors (e.g. `switches/@name=emoji/reset`) with the
    /// concrete list index found in the deployed config. Returns nil when not found.
    public func resolve(_ keypath: String, target: ConfigTarget) -> String? {
        guard keypath.contains("@"), keypath.contains("=") else { return keypath }
        var resolved: [String] = []
        for component in keypath.split(separator: "/").map(String.init) {
            guard component.hasPrefix("@"), let eq = component.firstIndex(of: "=") else {
                resolved.append(component)
                continue
            }
            let field = String(component[component.index(after: component.startIndex)..<eq])
            let wanted = String(component[component.index(after: eq)...])
            let parent = resolved.joined(separator: "/")
            let entries = built(target)?.value(at: parent)?.listValue ?? []
            guard let index = entries.firstIndex(where: { $0[field]?.stringValue == wanted }) else { return nil }
            resolved.append("@\(index)")
        }
        return resolved.joined(separator: "/")
    }

    // MARK: - Writing

    public enum WriteError: Error, CustomStringConvertible {
        case unknownTarget(String)
        case outOfRange(String)
        public var description: String {
            switch self {
            case let .unknownTarget(id): "no config target for setting \(id)"
            case let .outOfRange(id): "value out of range for \(id)"
            }
        }
    }

    /// Records a new value in the generated layer. Call deploy afterwards.
    public func set(_ value: ConfigValue, for setting: SettingCatalog.Setting, schemaID: String? = nil) throws {
        if setting.id == "grammar.language" {
            guard case let .string(name) = value else { throw WriteError.outOfRange(setting.id) }
            try setLanguageModel(name, schemaID: schemaID)
            return
        }
        guard let target = setting.target(schemaID: schemaID ?? primarySchema()) else {
            throw WriteError.unknownTarget(setting.id)
        }
        if let number = value.doubleValue {
            if let min = setting.min, number < min { throw WriteError.outOfRange(setting.id) }
            if let max = setting.max, number > max { throw WriteError.outOfRange(setting.id) }
        }
        if let toggled = setting.listItems, let enabled = value.boolValue {
            var entries = list(target: target, keypath: setting.keypath)
            entries.removeAll(where: toggled.contains)
            if enabled {
                entries.insert(contentsOf: toggled, at: Self.insertionPoint(for: toggled, in: entries))
            }
            entries = relocatingMisplacedVariants(entries, keypath: setting.keypath)
            try layers.setGenerated(target, keypath: setting.keypath, value: .list(entries))
            try yieldBracketKeys(to: setting, value: value, schemaID: schemaID)
            return
        }
        guard let keypath = resolve(setting.keypath, target: target) else { throw WriteError.unknownTarget(setting.id) }
        try layers.setGenerated(target, keypath: keypath, value: value)
        try yieldBracketKeys(to: setting, value: value, schemaID: schemaID)
    }

    static let bracketPaging = "keys.paging_brackets"
    static let selectCharacterKeys = ["key_binder.select_first_character", "key_binder.select_last_character"]
    static let bracketKeys: Set<String> = ["bracketleft", "bracketright"]

    /// select_character.lua runs before key_binder, so while 以词定字 uses [ or ] those
    /// keys never page (#13). The setting changed last wins: turning on [ ] paging clears
    /// 以词定字 keys still on a bracket, and recording a bracket for 以词定字 turns paging off.
    private func yieldBracketKeys(to setting: SettingCatalog.Setting, value: ConfigValue, schemaID: String?) throws {
        if setting.id == Self.bracketPaging, value.boolValue == true {
            for id in Self.selectCharacterKeys {
                guard let key = catalog.setting(id),
                      let current = self.value(for: key, schemaID: schemaID)?.stringValue,
                      Self.bracketKeys.contains(current) else { continue }
                try set(.string(""), for: key, schemaID: schemaID)
            }
        } else if Self.selectCharacterKeys.contains(setting.id), let key = value.stringValue, Self.bracketKeys.contains(key),
                  let paging = catalog.setting(Self.bracketPaging), self.value(for: paging, schemaID: schemaID)?.boolValue == true {
            try set(.bool(false), for: paging, schemaID: schemaID)
        }
    }

    private static func hasPrefix(_ entry: ConfigValue, _ prefixes: [String]) -> Bool {
        prefixes.contains { entry.stringValue?.hasPrefix($0) == true }
    }

    /// Where a toggled group of algebra rules goes. Spelling variants (derive/erase) must be
    /// derived from full pinyin: before abbreviations are generated and before double-pinyin
    /// schemas xform/xlit it into their keys — appended after those, `derive/^([zcs])h/` never
    /// matched (#9). Abbreviation groups keep their old place, so on double pinyin 超级简拼
    /// still abbreviates the keys rather than the full spelling.
    static func insertionPoint(for toggled: [ConfigValue], in entries: [ConfigValue]) -> Int {
        let stops = toggled.contains { hasPrefix($0, ["abbrev/"]) } ? ["abbrev/"] : ["abbrev/", "xform/", "xlit/"]
        return entries.firstIndex { hasPrefix($0, stops) } ?? entries.endIndex
    }

    func relocatingMisplacedVariants(_ entries: [ConfigValue], keypath: String) -> [ConfigValue] {
        Self.relocatingMisplacedVariants(entries, keypath: keypath, catalog: catalog)
    }

    /// Before #9 was fixed, spelling variants toggled on a double-pinyin schema landed after its
    /// xform/xlit rules. Moves any catalog variant found there back in front, keeping order.
    /// Runs on every toggle and once per deploy (`ConfigLayers.migrateSpellingVariants`).
    static func relocatingMisplacedVariants(_ entries: [ConfigValue], keypath: String, catalog: SettingCatalog) -> [ConfigValue] {
        let variants = Set(catalog.settings.filter { $0.keypath == keypath }
            .compactMap(\.listItems).filter { !$0.contains { Self.hasPrefix($0, ["abbrev/"]) } }
            .joined())
        guard let transform = entries.firstIndex(where: { Self.hasPrefix($0, ["xform/", "xlit/"]) }) else { return entries }
        let misplaced = entries[transform...].filter(variants.contains)
        guard !misplaced.isEmpty else { return entries }
        var kept = Array(entries[..<transform]) + entries[transform...].filter { !variants.contains($0) }
        kept.insert(contentsOf: misplaced, at: Self.insertionPoint(for: misplaced, in: kept))
        return kept
    }

    /// Drops the generated override so the imported / shipped value applies again.
    public func reset(_ setting: SettingCatalog.Setting, schemaID: String? = nil) throws {
        if setting.id == "grammar.language" {
            try resetLanguageModel(schemaID: schemaID)
            return
        }
        guard let target = setting.target(schemaID: schemaID ?? primarySchema()) else { return }
        guard let keypath = resolve(setting.keypath, target: target) else { return }
        try layers.setGenerated(target, keypath: keypath, value: nil)
        if Self.selectCharacterKeys.contains(setting.id) {
            // build/ still holds the value from before the reset until the next deploy.
            let below = ConfigLayers.compose([try layers.defaultsPatch(target), try layers.importedPatch(target)])
            let restored = below.last { $0.key == keypath }?.value
                ?? ConfigValue.map(below).value(at: keypath) ?? setting.default
            if let restored { try yieldBracketKeys(to: setting, value: restored, schemaID: schemaID) }
        }
    }

    /// Whether the generated layer overrides this setting.
    public func isCustomized(_ setting: SettingCatalog.Setting, schemaID: String? = nil) -> Bool {
        guard let target = setting.target(schemaID: schemaID ?? primarySchema()) else { return false }
        guard let keypath = resolve(setting.keypath, target: target) else { return false }
        return layers.generatedValue(target, keypath: keypath) != nil
    }
}
