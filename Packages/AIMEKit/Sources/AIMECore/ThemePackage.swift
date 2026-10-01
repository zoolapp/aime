public import Foundation

/// A shareable color theme (aime-theme v1, docs/themes.md): the 13 RIME color-scheme
/// keys as `0xAARRGGBB`, plus id, name and author. Exchanged through
/// `aime-ime://theme?v=1&d=<base64url JSON>` links; importing is always confirmed by the user.
public struct ThemePackage: Codable, Sendable, Equatable {
    public static let format = "aime-theme"
    /// v1: colors only. v2 adds `layout` (radii, padding, spacing, font sizes).
    public static let version = 2
    public static let maxBytes = 4096
    /// Qualified ("AIME input method") so no other app claims it (a bare `aime` is a common word).
    public static let urlScheme = "aime-ime"
    /// Settings' editable 「我的配色」; never replaced by an import.
    public static let reservedID = "aime_custom"
    public static let colorKeys = [
        "back_color", "border_color", "preedit_back_color", "text_color", "hilited_text_color",
        "hilited_back_color", "candidate_text_color", "comment_text_color", "label_color",
        "hilited_candidate_back_color", "hilited_candidate_text_color", "hilited_comment_text_color",
        "hilited_candidate_label_color",
    ]

    public var format: String
    public var version: Int
    public var id: String
    public var name: String
    public var author: String?
    /// Exactly `colorKeys`, values normalised to upper-case `0xAARRGGBB`.
    public var colors: [String: String]
    /// Panel geometry the theme was designed with (v2). Keys are RIME style keys.
    public var layout: [String: Double]?

    /// Accepted layout keys and their ranges (points).
    public static let layoutKeys: [(key: String, range: ClosedRange<Double>)] = [
        ("corner_radius", 0...30), ("hilited_corner_radius", 0...30),
        ("border_width", 0...30), ("border_height", 0...30),
        ("spacing", 0...40), ("line_spacing", 0...40),
        ("font_point", 10...40), ("label_font_point", 8...40), ("comment_font_point", 8...40),
    ]

    public init(id: String, name: String, author: String? = nil, colors: [String: String], layout: [String: Double]? = nil) {
        format = Self.format
        version = layout == nil ? 1 : 2
        self.id = id
        self.name = name
        self.author = author
        self.colors = colors
        self.layout = layout
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case notATheme
        case encoding
        case size
        case format
        case version(Int)
        case id(String)
        case reserved
        case name
        case colors([String])
        case layout([String])

        public var errorDescription: String? {
            switch self {
            case .notATheme: "这不是 AIME 主题链接"
            case .encoding: "主题链接已损坏，无法解码"
            case .size: "主题数据超过 4 KB"
            case .format: "不是 aime-theme 格式"
            case let .version(v): "不支持的主题版本 \(v)，请更新 AIME"
            case let .id(id): "主题 ID「\(id)」不合规（小写字母开头，2–32 位字母、数字或下划线）"
            case .reserved: "不能导入为「我的配色」"
            case .name: "主题名称需为 1–40 个字符"
            case let .colors(keys): "颜色缺失或格式不对：\(keys.joined(separator: "、"))"
            case let .layout(keys): "布局数值超出范围：\(keys.joined(separator: "、"))"
            }
        }
    }

    /// A decoded, validated package and the keys that were dropped.
    public struct Decoded: Sendable, Equatable {
        public var package: ThemePackage
        public var ignoredKeys: [String]
    }

    // MARK: - Links

    /// Parses `aime-ime://theme?v=1&d=…`.
    public static func decode(url: URL) throws(Failure) -> Decoded {
        guard url.scheme?.lowercased() == Self.urlScheme, url.host?.lowercased() == "theme",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let data = items.first(where: { $0.name == "d" })?.value
        else { throw .notATheme }
        if let v = items.first(where: { $0.name == "v" })?.value, !["1", "2"].contains(v) { throw .version(Int(v) ?? 0) }
        return try decode(payload: data)
    }

    /// Decodes and validates the base64url `d` parameter.
    public static func decode(payload: String) throws(Failure) -> Decoded {
        guard payload.count <= (maxBytes * 4 + 2) / 3, let data = base64URLDecode(payload) else {
            throw payload.count > (maxBytes * 4 + 2) / 3 ? .size : .encoding
        }
        return try decode(json: data)
    }

    public static func decode(json data: Data) throws(Failure) -> Decoded {
        guard data.count <= maxBytes else { throw .size }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw .encoding }
        guard object["format"] as? String == format else { throw .format }
        guard let version = object["version"] as? Int else { throw .format }
        guard (1...Self.version).contains(version) else { throw .version(version) }
        guard let id = object["id"] as? String else { throw .id("") }
        guard id.range(of: "^[a-z][a-z0-9_]{1,31}$", options: .regularExpression) != nil else { throw .id(id) }
        guard id != reservedID else { throw .reserved }
        guard let name = (object["name"] as? String).map(clean), (1...40).contains(name.count) else { throw .name }
        let author = (object["author"] as? String).map(clean).map { String($0.prefix(40)) }.flatMap { $0.isEmpty ? nil : $0 }
        let rawColors = object["colors"] as? [String: Any] ?? [:]
        var colors: [String: String] = [:]
        var bad: [String] = []
        for key in colorKeys {
            if let value = (rawColors[key] as? String).flatMap(normalizedColor) { colors[key] = value } else { bad.append(key) }
        }
        guard bad.isEmpty else { throw .colors(bad) }
        var layout: [String: Double]?
        var ignoredLayout: [String] = []
        if version >= 2, let rawLayout = object["layout"] as? [String: Any] {
            var values: [String: Double] = [:]
            var outOfRange: [String] = []
            for (key, range) in layoutKeys {
                guard let raw = rawLayout[key] else { continue }
                guard let number = (raw as? NSNumber)?.doubleValue, number.isFinite, range.contains(number) else { outOfRange.append(key); continue }
                values[key] = (number * 2).rounded() / 2
            }
            guard outOfRange.isEmpty else { throw .layout(outOfRange) }
            layout = values.isEmpty ? nil : values
            ignoredLayout = rawLayout.keys.filter { key in !layoutKeys.contains { $0.key == key } }.map { "layout.\($0)" }.sorted()
        }
        let known = Set(["format", "version", "id", "name", "author", "colors"] + (version >= 2 ? ["layout"] : []))
        let ignored = object.keys.filter { !known.contains($0) }.sorted()
            + rawColors.keys.filter { !colorKeys.contains($0) }.map { "colors.\($0)" }.sorted() + ignoredLayout
        return Decoded(package: ThemePackage(id: id, name: name, author: author, colors: colors, layout: layout), ignoredKeys: ignored)
    }

    /// Canonical JSON: sorted keys, no whitespace, UTF-8, `/` not escaped.
    public func canonicalJSON() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    public var payload: String { Self.base64URLEncode(canonicalJSON()) }
    public var url: URL { URL(string: "\(Self.urlScheme)://theme?v=\(version)&d=\(payload)")! }

    /// The `preset_color_schemes/<id>` value written on import.
    public var schemeValue: ConfigValue {
        var entries: [ConfigValue.Entry] = [.init("name", .string(name))]
        if let author { entries.append(.init("author", .string(author))) }
        entries.append(.init("color_format", "argb"))
        entries += Self.colorKeys.map { .init($0, .string(colors[$0] ?? "0x00000000")) }
        for (key, _) in Self.layoutKeys { if let value = layout?[key] { entries.append(.init(key, .double(value))) } }
        return .map(entries)
    }

    /// `0xAARRGGBB` (or `#RRGGBB` / `0xRRGGBB`, made opaque) → `0xAARRGGBB` upper case.
    static func normalizedColor(_ text: String) -> String? {
        var hex = text.trimmingCharacters(in: .whitespaces).lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) } else if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, hex.allSatisfy(\.isHexDigit) else { return nil }
        return "0x" + (hex.count == 6 ? "ff" + hex : hex).uppercased()
    }

    private static func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).trimmingCharacters(in: .whitespaces)
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ text: String) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        return Data(base64Encoded: base)
    }
}

/// What importing a theme would change, computed without touching any file.
public struct ThemeImportPlan: Sendable, Equatable {
    public enum Target: String, Sendable, CaseIterable { case light, dark, both }

    public var package: ThemePackage
    /// The id names a scheme shipped with AIME: nothing is written, it is only selected.
    public var isBuiltIn: Bool
    /// An earlier import with the same id exists in the generated layer and will be replaced.
    public var replaces: String?

    public init(package: ThemePackage, frontend: ConfigValue, generatedPatch: [ConfigValue.Entry]) {
        self.package = package
        let key = "preset_color_schemes/\(package.id)"
        let imported = generatedPatch.first { $0.key == key }
        let exists = frontend.value(at: key) != nil
        isBuiltIn = exists && imported == nil
        replaces = imported.map { $0.value["name"]?.stringValue ?? package.id }
    }

    /// Applies the plan to the generated frontend patch. Only the scheme and the
    /// selected `style/color_scheme(_dark)` keys change; `aime_custom` is never touched.
    /// `adoptLayout` also writes the theme's geometry as the user's panel settings
    /// (`style/aime/*`, which win over any scheme), so the panel matches the theme preview.
    public func apply(to patch: inout [ConfigValue.Entry], activate: Bool, target: Target, adoptLayout: Bool = false) {
        if adoptLayout, let layout = package.layout {
            for (key, _) in ThemePackage.layoutKeys {
                guard let value = layout[key] else { continue }
                patch.removeAll { $0.key == "style/aime/\(key)" }
                patch.append(.init("style/aime/\(key)", .double(value)))
            }
        }
        if !isBuiltIn {
            let key = "preset_color_schemes/\(package.id)"
            patch.removeAll { $0.key == key || $0.key.hasPrefix(key + "/") }
            patch.append(.init(key, package.schemeValue))
        }
        guard activate else { return }
        let keys: [String] = switch target {
        case .light: ["style/color_scheme"]
        case .dark: ["style/color_scheme_dark"]
        case .both: ["style/color_scheme", "style/color_scheme_dark"]
        }
        patch.removeAll { keys.contains($0.key) }
        for key in keys { patch.append(.init(key, .string(package.id))) }
    }
}
