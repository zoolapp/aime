public import Foundation
internal import Yams

/// A YAML value as used by Rime configs. Maps keep insertion order so generated
/// files stay stable and diff-friendly.
public indirect enum ConfigValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case list([ConfigValue])
    case map([Entry])

    public struct Entry: Sendable, Hashable {
        public var key: String
        public var value: ConfigValue
        public init(_ key: String, _ value: ConfigValue) {
            self.key = key
            self.value = value
        }
    }

    public var boolValue: Bool? { if case let .bool(v) = self { v } else { nil } }
    public var intValue: Int? {
        switch self {
        case let .int(v): v
        case let .double(v) where v.rounded() == v: Int(v)
        default: nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case let .double(v): v
        case let .int(v): Double(v)
        default: nil
        }
    }
    public var stringValue: String? {
        switch self {
        case let .string(v): v
        case let .int(v): String(v)
        case let .double(v): String(v)
        case let .bool(v): v ? "true" : "false"
        default: nil
        }
    }
    public var listValue: [ConfigValue]? { if case let .list(v) = self { v } else { nil } }
    public var entries: [Entry]? { if case let .map(v) = self { v } else { nil } }

    public subscript(key: String) -> ConfigValue? {
        guard case let .map(entries) = self else { return nil }
        return entries.last { $0.key == key }?.value
    }

    /// Resolves a Rime keypath such as `menu/page_size` or `schema_list/@0/schema`.
    public func value(at keypath: String) -> ConfigValue? {
        var node: ConfigValue? = self
        for component in keypath.split(separator: "/").map(String.init) {
            guard let current = node else { return nil }
            if component.hasPrefix("@"), let list = current.listValue {
                let index: Int? = component == "@last" ? list.indices.last : Int(component.dropFirst())
                guard let index, list.indices.contains(index) else { return nil }
                node = list[index]
            } else {
                node = current[component]
            }
        }
        return node
    }

    /// Sets a value at a keypath of map keys, creating intermediate maps.
    public mutating func set(_ newValue: ConfigValue?, at keypath: String) {
        let components = keypath.split(separator: "/").map(String.init)
        self = Self.setting(newValue, components: components[...], in: self)
    }

    private static func setting(_ newValue: ConfigValue?, components: ArraySlice<String>, in node: ConfigValue) -> ConfigValue {
        guard let head = components.first else { return newValue ?? .null }
        var entries = node.entries ?? []
        let index = entries.lastIndex { $0.key == head }
        if components.count == 1 {
            if let newValue {
                if let index { entries[index].value = newValue } else { entries.append(Entry(head, newValue)) }
            } else if let index {
                entries.remove(at: index)
            }
        } else {
            let child = index.map { entries[$0].value } ?? .map([])
            let updated = setting(newValue, components: components.dropFirst(), in: child)
            if let index { entries[index].value = updated } else { entries.append(Entry(head, updated)) }
        }
        return .map(entries)
    }
}

extension ConfigValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: ConfigValue...) { self = .list(elements) }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - YAML bridging

public enum YAMLError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self { case let .invalid(message): message }
    }
}

extension ConfigValue {
    /// Parses a YAML document. Throws with the parser's message on syntax errors.
    public static func parse(yaml: String) throws -> ConfigValue {
        do {
            guard let node = try Yams.compose(yaml: yaml) else { return .map([]) }
            return ConfigValue(node: node)
        } catch {
            throw YAMLError.invalid(String(describing: error))
        }
    }

    public static func load(contentsOf url: URL) throws -> ConfigValue {
        try parse(yaml: String(contentsOf: url, encoding: .utf8))
    }

    init(node: Node) {
        switch node {
        case let .scalar(scalar):
            self = Self.interpret(scalar)
        case let .sequence(sequence):
            self = .list(sequence.map(ConfigValue.init(node:)))
        case let .mapping(mapping):
            self = .map(mapping.map { Entry($0.key.string ?? "", ConfigValue(node: $0.value)) })
        case let .alias(alias):
            self = .string(String(describing: alias))
        }
    }

    private static func interpret(_ scalar: Node.Scalar) -> ConfigValue {
        // Quoted scalars are always strings.
        if scalar.style == .singleQuoted || scalar.style == .doubleQuoted || scalar.style == .literal || scalar.style == .folded {
            return .string(scalar.string)
        }
        let text = scalar.string
        switch text {
        case "", "~", "null", "Null", "NULL": return text.isEmpty ? .string("") : .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        default: break
        }
        if let int = Int(text) { return .int(int) }
        if text.contains("."), let double = Double(text), !text.hasPrefix(".") { return .double(double) }
        return .string(text)
    }

    var node: Node {
        switch self {
        case .null: return Node("~", Tag(.null))
        case let .bool(value): return Node(value ? "true" : "false", Tag(.bool))
        case let .int(value): return Node(String(value), Tag(.int))
        case let .double(value): return Node(String(value), Tag(.float))
        case let .string(value):
            // Quote anything YAML could reinterpret (numbers, booleans, symbols, leading spaces).
            let plainSafe = !value.isEmpty
                && ConfigValue.interpret(Node.Scalar(value)) == .string(value)
                && value.rangeOfCharacter(from: CharacterSet(charactersIn: ":#{}[],&*!|>'\"%@`")) == nil
                && value.trimmingCharacters(in: .whitespaces) == value
            return Node(value, Tag(.str), plainSafe ? .plain : .doubleQuoted)
        case let .list(values):
            return Node(values.map(\.node))
        case let .map(entries):
            return Node(entries.map { (Node($0.key), $0.value.node) })
        }
    }

    /// Serializes as a block-style YAML document.
    public func yamlString() throws -> String {
        try Yams.serialize(node: node, indent: 2, width: -1, allowUnicode: true, sortKeys: false)
    }
}
