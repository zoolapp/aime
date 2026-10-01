public import Foundation

/// Machine-readable description of every visually editable Rime setting.
/// Source of truth: `config/catalog.json` (copied into the package resources).
public struct SettingCatalog: Sendable, Decodable {
    public struct Group: Sendable, Decodable, Identifiable, Hashable {
        public let id: String
        public let title: String
        public let icon: String?
        public let description: String?
    }

    public struct Option: Sendable, Decodable, Hashable, Identifiable {
        public let value: ConfigValue
        public let title: String
        public var id: String { value.stringValue ?? title }
    }

    public enum Kind: String, Sendable, Decodable {
        case bool, int, double, string, `enum`, color, font, hotkey, stringList
        /// Several hotkeys, recorded with the key recorder.
        case hotkeyList
        /// Option names picked from the primary schema's `switches`.
        case switchList
        /// A `.gram` language model picked from the data directories.
        case gramModel
        /// Edited by a dedicated page (schema list, app options), not a generic control.
        case custom
    }

    public struct Setting: Sendable, Decodable, Identifiable, Hashable {
        public let id: String
        public let group: String
        public let title: String
        public let description: String?
        /// `default`, `schema` or `frontend`.
        public let file: String
        public let keypath: String
        public let type: Kind
        public let min: Double?
        public let max: Double?
        public let step: Double?
        public let options: [Option]?
        public let `default`: ConfigValue?
        /// For spelling toggles: algebra rules present while the toggle is on.
        public let algebra: [String]?
        /// For other list toggles (e.g. key bindings): entries present while on.
        public let items: [ConfigValue]?
        public let doc: String?

        public func target(schemaID: String?) -> ConfigTarget? {
            ConfigTarget(file: file, schemaID: schemaID)
        }

        /// Toggles that add/remove entries of a shared list (`speller/algebra`,
        /// `key_binder/bindings`) rather than setting a scalar.
        public var listItems: [ConfigValue]? {
            if let algebra, !algebra.isEmpty { return algebra.map(ConfigValue.string) }
            if let items, !items.isEmpty { return items }
            return nil
        }

        public var isListToggle: Bool { listItems != nil }
    }

    public let version: Int
    public let groups: [Group]
    public let settings: [Setting]

    public func settings(in group: String) -> [Setting] { settings.filter { $0.group == group } }
    public func setting(_ id: String) -> Setting? { settings.first { $0.id == id } }

    public static func load(from url: URL) throws -> SettingCatalog {
        try JSONDecoder().decode(SettingCatalog.self, from: Data(contentsOf: url))
    }

    /// The catalog bundled with AIMECore.
    public static let bundled: SettingCatalog = {
        guard let url = CoreResources.url(forResource: "catalog", withExtension: "json") ?? Bundle.module.url(forResource: "catalog", withExtension: "json"),
              let catalog = try? load(from: url)
        else { return SettingCatalog(version: 0, groups: [], settings: []) }
        return catalog
    }()

    public init(version: Int, groups: [Group], settings: [Setting]) {
        self.version = version
        self.groups = groups
        self.settings = settings
    }
}

extension ConfigValue: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([ConfigValue].self) { self = .list(value) }
        else if let value = try? container.decode([String: ConfigValue].self) {
            self = .map(value.keys.sorted().map { Entry($0, value[$0]!) })
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported value")
        }
    }
}

extension ConfigValue: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .list(value): try container.encode(value)
        case let .map(entries):
            try container.encode(Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last }))
        }
    }
}
