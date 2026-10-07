import Foundation

public enum LanguageModelSettingsError: Error, Equatable, CustomStringConvertible {
    case invalidName(String)
    case missingModel(String)
    case missingSchema(String?)

    public var description: String {
        switch self {
        case let .invalidName(name): "语言模型名称无效：\(name)"
        case let .missingModel(name): "未找到可用的本地语言模型：\(name).gram"
        case let .missingSchema(id): "未找到输入方案：\(id ?? "尚未选择默认方案")"
        }
    }
}

extension SettingsStore {
    /// Grammar defaults from amzxyz/rime-wanxiang v18.0.15 (CC-BY-4.0):
    /// https://github.com/amzxyz/rime-wanxiang/blob/v18.0.15/wanxiang.schema.yaml
    /// The ownership map lets Reset remove only parameters this helper supplied.
    private static let languageModelDefaults: [ConfigValue.Entry] = [
        .init("grammar/collocation_max_length", 6),
        .init("grammar/collocation_min_length", 2),
        .init("grammar/collocation_penalty", -14),
        .init("grammar/non_collocation_penalty", -6),
        .init("grammar/weak_collocation_penalty", -100),
        .init("grammar/rear_penalty", -18),
    ]
    private static let languageModelOwnershipKey = "aime/_language_model_defaults"

    /// Selects an existing local model and supplies missing Grammar parameters in one
    /// generated-layer edit. This does not enable cross-commit contextual suggestions.
    /// An empty name disables the model without changing its parameters or other options.
    public func setLanguageModel(_ name: String, schemaID: String? = nil) throws {
        let (target, source) = try languageModelTarget(schemaID: schemaID)
        if name.isEmpty {
            try layers.updateGenerated(target) { patch in
                Self.replaceLanguageModelEntry("grammar/language", value: "", in: &patch)
            }
            return
        }
        guard Self.isSafeLanguageModelName(name) else { throw LanguageModelSettingsError.invalidName(name) }
        guard hasLanguageModelFile(named: name) else { throw LanguageModelSettingsError.missingModel(name) }

        // installShim will adopt a foreign custom file as the imported layer. Read it
        // now too, so automatic defaults cannot override the settings being adopted.
        let imported = try layers.hasForeignCustomFile(target)
            ? ConfigLayers.patchEntries(at: layers.shimURL(target))
            : layers.importedPatch(target)
        let defaults = try layers.defaultsPatch(target)
        let deployed = built(target)
        try layers.updateGenerated(target) { patch in
            let owned = Self.languageModelOwnedEntries(in: patch)
            Self.removeLanguageModelDefaults(owned, from: &patch)
            let combined = ConfigLayers.compose([defaults, imported, patch])
            let effective = Self.applyingLanguageModelPatch(combined, to: source)

            var supplied: [ConfigValue.Entry] = []
            for entry in Self.languageModelDefaults where effective.value(at: entry.key) == nil || effective.value(at: entry.key) == .null {
                // Deployed values may come from an include which the source preview
                // cannot resolve. Keep those, but do not mistake our old defaults for
                // inherited settings after imported/source configuration has changed.
                let inherited = deployed?.value(at: entry.key)
                let wasAutomatic = owned.contains { $0.key == entry.key && Self.sameLanguageModelValue($0.value, inherited) }
                let value: ConfigValue
                if let inherited, inherited != .null, !wasAutomatic { value = inherited }
                else { value = entry.value }
                Self.replaceLanguageModelEntry(entry.key, value: value, in: &patch)
                supplied.append(.init(entry.key, value))
            }
            if !supplied.isEmpty {
                Self.replaceLanguageModelEntry(Self.languageModelOwnershipKey, value: .map(supplied), in: &patch)
            }
            Self.replaceLanguageModelEntry("grammar/language", value: .string(name), in: &patch)
        }
    }

    /// Restores the imported/source language and removes unchanged automatic defaults.
    /// Parameters subsequently edited by the user remain in the generated layer.
    public func resetLanguageModel(schemaID: String? = nil) throws {
        let (target, _) = try languageModelTarget(schemaID: schemaID)
        try layers.updateGenerated(target) { patch in
            Self.removeLanguageModelDefaults(Self.languageModelOwnedEntries(in: patch), from: &patch)
            patch.removeAll { $0.key == "grammar/language" }
        }
    }

    /// Clears references before a model uninstall, including schemes which
    /// are disabled or whose imported/generated changes have not been deployed yet.
    public func disableLanguageModelReferences(named name: String) throws {
        guard Self.isSafeLanguageModelName(name) else { throw LanguageModelSettingsError.invalidName(name) }
        var references: [String] = []
        for schema in SchemaDiscovery.available(paths: paths) {
            let (target, source) = try languageModelTarget(schemaID: schema.id)
            let imported = try layers.hasForeignCustomFile(target)
                ? ConfigLayers.patchEntries(at: layers.shimURL(target))
                : layers.importedPatch(target)
            let combined = ConfigLayers.compose([
                try layers.defaultsPatch(target), imported, try layers.generatedPatch(target),
            ])
            let effective = Self.applyingLanguageModelPatch(combined, to: source)
            let pending = effective.value(at: "grammar/language")
            // A pending replacement or explicit empty/null language takes precedence
            // over stale deployed output. Includes may only be visible in build/.
            let language = pending == nil ? built(target)?.value(at: "grammar/language") : pending
            if language?.stringValue == name { references.append(schema.id) }
        }
        for id in references { try setLanguageModel("", schemaID: id) }
    }

    private static func applyingLanguageModelPatch(_ patch: [ConfigValue.Entry], to source: ConfigValue) -> ConfigValue {
        var effective = source
        for entry in patch.sorted(by: { $0.key < $1.key })
        where entry.key == "grammar" || entry.key.hasPrefix("grammar/") {
            let key = entry.key.hasSuffix("/=") ? String(entry.key.dropLast(2)) : entry.key
            effective.set(entry.value, at: key)
        }
        return effective
    }

    private func languageModelTarget(schemaID: String?) throws -> (ConfigTarget, ConfigValue) {
        guard let id = schemaID ?? pendingSchemas().first, Self.isSafeLanguageModelName(id) else {
            throw LanguageModelSettingsError.missingSchema(schemaID)
        }
        for directory in [paths.userDataDir, paths.sharedDataDir].compactMap({ $0 }) {
            let url = directory.appendingPathComponent("\(id).schema.yaml")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let source = try ConfigValue.load(contentsOf: url)
            guard source.value(at: "schema/schema_id")?.stringValue == id else {
                throw LanguageModelSettingsError.missingSchema(id)
            }
            return (.schema(id), source)
        }
        throw LanguageModelSettingsError.missingSchema(id)
    }

    private static func isSafeLanguageModelName(_ name: String) -> Bool {
        func alphanumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        guard let first = name.utf8.first, alphanumeric(first), name.utf8.count <= 200, !name.contains("..") else { return false }
        return name.utf8.allSatisfy { alphanumeric($0) || $0 == 45 || $0 == 46 || $0 == 95 }
    }

    private func hasLanguageModelFile(named name: String) -> Bool {
        for directory in [paths.userDataDir, paths.sharedDataDir].compactMap({ $0 }) {
            let url = directory.appendingPathComponent("\(name).gram")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // A user-directory file shadows shared data even when it is unusable.
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? 0) > 0
        }
        return false
    }

    private static func languageModelOwnedEntries(in patch: [ConfigValue.Entry]) -> [ConfigValue.Entry] {
        let keys = Set(languageModelDefaults.map(\.key))
        return (patch.last { $0.key == languageModelOwnershipKey }?.value.entries ?? []).filter { keys.contains($0.key) }
    }

    private static func removeLanguageModelDefaults(_ owned: [ConfigValue.Entry], from patch: inout [ConfigValue.Entry]) {
        patch.removeAll { entry in
            entry.key == languageModelOwnershipKey || owned.contains {
                $0.key == entry.key && sameLanguageModelValue($0.value, entry.value)
            }
        }
    }

    // Deployed Rime YAML can quote negative numbers; compare their numeric meaning.
    private static func sameLanguageModelValue(_ lhs: ConfigValue, _ rhs: ConfigValue?) -> Bool {
        guard let rhs else { return false }
        if lhs == rhs { return true }
        guard let left = lhs.doubleValue ?? lhs.stringValue.flatMap(Double.init),
              let right = rhs.doubleValue ?? rhs.stringValue.flatMap(Double.init) else { return false }
        return left == right
    }

    private static func replaceLanguageModelEntry(_ key: String, value: ConfigValue, in patch: inout [ConfigValue.Entry]) {
        patch.removeAll { $0.key == key }
        patch.append(.init(key, value))
    }
}
