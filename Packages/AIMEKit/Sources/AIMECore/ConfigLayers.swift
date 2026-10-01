public import Foundation
import os

/// Three-layer customization on top of Rime's `*.custom.yaml` convention.
///
/// | Layer     | File                                      | Owner                          |
/// |-----------|-------------------------------------------|--------------------------------|
/// | defaults  | `SharedSupport/aime/defaults/<name>.yaml` | ships with AIME                |
/// | imported  | `aime/imported/<name>.custom.yaml`        | the user (verbatim, hand-written) |
/// | generated | `aime/generated/<name>.yaml`              | AIME Settings                  |
///
/// AIME owns the top-level `<name>.custom.yaml` and writes it as a *composed*, flat
/// patch: the `patch:` entries of all layers, later layers replacing earlier ones.
///
/// Why not reference the layers with `__patch` / `__include` from the custom file?
/// Those directives *execute* keypaths against the `patch:` node itself, turning
/// `menu/page_size: 5` into a nested `menu:` map that then replaces the whole `menu`
/// section of the target (see docs/decisions/0003-user-directory-and-patch-layering.md).
/// A literal, composed patch keeps librime's normal keypath semantics: librime applies
/// patch keys in sorted order, so a parent key (`style`) always lands before a child
/// key (`style/color_scheme`).
public struct ConfigLayers: Sendable {
    public static let shimMarker = "# Managed by AIME"

    public let paths: AIMEPaths

    public init(paths: AIMEPaths) {
        self.paths = paths
    }

    public func shimURL(_ target: ConfigTarget) -> URL {
        paths.userDataDir.appendingPathComponent("\(target.customName).custom.yaml")
    }

    public func importedURL(_ target: ConfigTarget) -> URL {
        paths.importedDir.appendingPathComponent("\(target.customName).custom.yaml")
    }

    public func generatedURL(_ target: ConfigTarget) -> URL {
        paths.generatedDir.appendingPathComponent("\(target.customName).yaml")
    }

    /// Shipped defaults; a copy in the user directory takes precedence.
    public func defaultsURL(_ target: ConfigTarget) -> URL? {
        let relative = "aime/defaults/\(target.customName).yaml"
        let user = paths.userDataDir.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: user.path) { return user }
        guard let shared = paths.sharedDataDir?.appendingPathComponent(relative),
              FileManager.default.fileExists(atPath: shared.path) else { return nil }
        return shared
    }

    /// True when `<name>.custom.yaml` exists and was not written by AIME.
    public func hasForeignCustomFile(_ target: ConfigTarget) -> Bool {
        let url = shimURL(target)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return !text.hasPrefix(Self.shimMarker)
    }

    // MARK: - Layers

    public enum LayerError: Error, CustomStringConvertible {
        case unreadable(URL, String)
        case notAPatch(URL)

        public var description: String {
            switch self {
            case let .unreadable(url, reason): "无法解析 \(url.lastPathComponent)：\(reason)"
            case let .notAPatch(url): "\(url.lastPathComponent) 的 patch 不是映射（map）"
            }
        }
    }

    /// Reads a layer's `patch:` entries. A missing file is an empty layer; an existing
    /// file that cannot be parsed is an error — silently treating it as empty would
    /// drop the user's settings from the composed shim.
    static func patchEntries(at url: URL?) throws -> [ConfigValue.Entry] {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return [] }
        let document: ConfigValue
        do { document = try ConfigValue.load(contentsOf: url) } catch {
            throw LayerError.unreadable(url, String(describing: error))
        }
        guard let patch = document["patch"] else { return [] }
        if case .null = patch { return [] }
        guard let entries = patch.entries else { throw LayerError.notAPatch(url) }
        return entries
    }

    public func defaultsPatch(_ target: ConfigTarget) throws -> [ConfigValue.Entry] { try Self.patchEntries(at: defaultsURL(target)) }
    public func importedPatch(_ target: ConfigTarget) throws -> [ConfigValue.Entry] { try Self.patchEntries(at: importedURL(target)) }
    public func generatedPatch(_ target: ConfigTarget) throws -> [ConfigValue.Entry] { try Self.patchEntries(at: generatedURL(target)) }

    public func generatedValue(_ target: ConfigTarget, keypath: String) -> ConfigValue? {
        (try? generatedPatch(target))?.last { $0.key == keypath }?.value
    }

    /// Merges layers into one literal patch.
    ///
    /// * Across layers, a key replaces the same key and every descendant key of earlier
    ///   layers (`style` drops an earlier `style/font_point`).
    /// * Within one layer nothing is removed: librime applies a patch in sorted key
    ///   order, so a parent key already lands before its children.
    /// * An append (`k/+`) whose target an earlier layer replaced (`k` or `k/=`) is folded
    ///   into that list, because sorted order would otherwise run the append first.
    public static func compose(_ layers: [[ConfigValue.Entry]]) -> [ConfigValue.Entry] {
        var composed: [ConfigValue.Entry] = []
        for layer in layers {
            let entries = layer.flatMap(expandCollections)
            let earlierCount = composed.count
            var earlier = Array(composed[..<earlierCount])
            var current: [ConfigValue.Entry] = []
            for entry in entries {
                let key = entry.key
                if key.hasSuffix("/+") {
                    let base = String(key.dropLast(2))
                    if let index = earlier.lastIndex(where: { $0.key == base || $0.key == base + "/=" }),
                       let list = earlier[index].value.listValue, let extra = entry.value.listValue {
                        earlier[index].value = .list(list + extra)
                    } else if let index = earlier.lastIndex(where: { $0.key == key }),
                              let list = earlier[index].value.listValue, let extra = entry.value.listValue {
                        earlier[index].value = .list(list + extra)
                    } else {
                        current.append(entry)
                    }
                    continue
                }
                let base = key.hasSuffix("/=") ? String(key.dropLast(2)) : key
                earlier.removeAll { $0.key == key || $0.key == base || $0.key == base + "/=" || $0.key.hasPrefix(base + "/") }
                current.append(entry)
            }
            composed = earlier + current
        }
        return composed
    }

    /// Keys whose children are independent named items. Patching the whole map (common
    /// in squirrel.custom.yaml) would wipe the items AIME ships, so it is split into one
    /// key per item: user items still win, shipped items survive.
    static let collectionKeys: Set<String> = ["preset_color_schemes", "app_options"]

    static func expandCollections(_ entry: ConfigValue.Entry) -> [ConfigValue.Entry] {
        // An empty map keeps its meaning ("clear the collection").
        guard collectionKeys.contains(entry.key), let children = entry.value.entries, !children.isEmpty else { return [entry] }
        return children.map { ConfigValue.Entry("\(entry.key)/\($0.key)", $0.value) }
    }

    public func composedPatch(_ target: ConfigTarget) throws -> [ConfigValue.Entry] {
        Self.compose([try defaultsPatch(target), try importedPatch(target), try generatedPatch(target)])
    }

    /// Writes the composed shim. A pre-existing hand-written custom file is moved into
    /// the imported layer first so nothing the user wrote is lost.
    public func installShim(_ target: ConfigTarget) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.importedDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.generatedDir, withIntermediateDirectories: true)
        let shim = shimURL(target)
        if hasForeignCustomFile(target) {
            let imported = importedURL(target)
            if fm.fileExists(atPath: imported.path) { try backup(imported) }
            try fm.moveItem(at: shim, to: imported)
        }
        let patch = try composedPatch(target)
        let header = """
        \(Self.shimMarker) — do not edit by hand; regenerated before every deploy.
        # Layers, in order (later wins):
        #   defaults   aime/defaults/\(target.customName).yaml (shipped with AIME)
        #   imported   aime/imported/\(target.customName).custom.yaml (edit this for hand-written patches)
        #   generated  aime/generated/\(target.customName).yaml (AIME Settings)

        """
        let body = patch.isEmpty ? "patch: {}\n" : try ConfigValue.map([.init("patch", .map(patch))]).yamlString()
        let contents = header + body
        if (try? String(contentsOf: shim, encoding: .utf8)) != contents {
            try contents.write(to: shim, atomically: true, encoding: .utf8)
            invalidateBuild(target)
        }
    }

    /// Sets (or removes, when `value` is nil) one keypath in the generated layer.
    public func setGenerated(_ target: ConfigTarget, keypath: String, value: ConfigValue?) throws {
        try updateGenerated(target) { patch in
            if let index = patch.firstIndex(where: { $0.key == keypath }) {
                if let value { patch[index].value = value } else { patch.remove(at: index) }
            } else if let value {
                patch.append(ConfigValue.Entry(keypath, value))
            }
        }
    }

    public func updateGenerated(_ target: ConfigTarget, _ body: (inout [ConfigValue.Entry]) throws -> Void) throws {
        // Throws on a corrupt generated file instead of overwriting it with one edit.
        var patch = try generatedPatch(target)
        try body(&patch)
        try FileManager.default.createDirectory(at: paths.generatedDir, withIntermediateDirectories: true)
        let header = "# Generated by AIME Settings. Safe to delete to reset visual settings.\n"
        let body = patch.isEmpty ? "patch: {}\n" : try ConfigValue.map([.init("patch", .map(patch))]).yamlString()
        try (header + body).write(to: generatedURL(target), atomically: true, encoding: .utf8)
        try installShim(target)
    }

    /// Replaces the whole imported layer for a target with raw YAML (advanced editor).
    public func writeImported(_ target: ConfigTarget, yaml: String) throws {
        let document = try ConfigValue.parse(yaml: yaml)
        if let patch = document["patch"], patch.entries == nil, patch != .null {
            throw LayerError.notAPatch(importedURL(target))
        }
        try FileManager.default.createDirectory(at: paths.importedDir, withIntermediateDirectories: true)
        try yaml.write(to: importedURL(target), atomically: true, encoding: .utf8)
        try installShim(target)
    }

    /// Moves a file into `aime/backup/<timestamp>/` instead of deleting it.
    public func backup(_ url: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let folder = paths.aimeDir.appendingPathComponent("backup/\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        }
        try FileManager.default.moveItem(at: url, to: destination)
    }

    // MARK: - Deploy bookkeeping

    /// librime compares source timestamps at one-second resolution, so two edits within
    /// the same second would be missed. Edited targets are recorded as dirty and their
    /// built files are dropped right before the next deploy (`prepareForDeploy`), which
    /// keeps `build/` readable for the settings UI in the meantime.
    public func invalidateBuild(_ target: ConfigTarget) {
        var dirty = dirtyTargets()
        dirty.insert(target.configID)
        try? FileManager.default.createDirectory(at: paths.aimeDir, withIntermediateDirectories: true)
        try? dirty.sorted().joined(separator: "\n").write(to: dirtyListURL, atomically: true, encoding: .utf8)
    }

    var dirtyListURL: URL { paths.aimeDir.appendingPathComponent(".dirty") }

    public func dirtyTargets() -> Set<String> {
        guard let text = try? String(contentsOf: dirtyListURL, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    /// Re-composes every managed shim (picking up hand edits to imported files and new
    /// shipped defaults), then removes built output of dirty targets so librime rebuilds
    /// them. Call immediately before starting maintenance.
    @discardableResult
    public func prepareForDeploy(extraTargets: [ConfigTarget] = []) throws -> [String] {
        migrateStyleOverrides()
        // Vocabulary tables (bundled + subscribed) are regenerated only when their inputs changed.
        do {
            try SubscriptionManager(paths: paths).ensureTables()
        } catch {
            // Keep the previous tables; vocabulary is never worth failing a deploy for.
            Logger(subsystem: "app.zool.aime", category: "vocabulary").error("vocabulary tables: \(String(describing: error), privacy: .public)")
        }
        // A broken layer aborts the deploy; the previous build stays in place.
        for target in Set(managedTargets() + extraTargets).sorted(by: { $0.configID < $1.configID }) {
            try installShim(target)
        }
        let dirty = dirtyTargets().sorted()
        for configID in dirty {
            try? FileManager.default.removeItem(at: paths.builtConfig(configID))
        }
        try? FileManager.default.removeItem(at: dirtyListURL)
        return dirty
    }

    /// Visual settings made in AIME Settings live under `style/aime/*` (they win over the
    /// color scheme). Older versions wrote them to `style/*`; move those once.
    func migrateStyleOverrides() {
        let moved = SettingCatalog.bundled.settings
            .filter { $0.file == "frontend" && $0.keypath.hasPrefix("style/aime/") }
            .map { (old: "style/" + $0.keypath.dropFirst("style/aime/".count), new: $0.keypath) }
        guard let patch = try? generatedPatch(.frontend), patch.contains(where: { entry in moved.contains { $0.old == entry.key } }) else { return }
        try? updateGenerated(.frontend) { patch in
            for pair in moved {
                guard let index = patch.firstIndex(where: { $0.key == pair.old }) else { continue }
                let value = patch[index].value
                patch.remove(at: index)
                if !patch.contains(where: { $0.key == pair.new }) { patch.append(.init(pair.new, value)) }
            }
        }
    }

    /// Every target that currently has a shim in the user directory.
    public func managedTargets() -> [ConfigTarget] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: paths.userDataDir.path) else { return [] }
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".custom.yaml") else { return nil }
            let target = ConfigTarget(customName: String(name.dropLast(".custom.yaml".count)))
            return hasForeignCustomFile(target) ? nil : target
        }
    }
}

extension ConfigTarget {
    /// Inverse of `customName`.
    public init(customName: String) {
        switch customName {
        case "default": self = .default
        case "aime": self = .frontend
        default: self = .schema(customName)
        }
    }
}
