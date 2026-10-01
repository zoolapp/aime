public import AIMECore
public import Foundation

/// Turns a natural-language request ("候选词改成 7 个，开启 zh/z 模糊音") into validated
/// catalog changes. The model only proposes; every change is type-checked against the
/// catalog and shown to the user as a diff before anything is written.
public struct ConfigAssistant: Sendable {
    public struct Proposal: Sendable, Identifiable, Equatable {
        public var id: String { setting.id }
        public let setting: SettingCatalog.Setting
        public let current: ConfigValue?
        public let proposed: ConfigValue
    }

    public struct Result: Sendable {
        public var proposals: [Proposal]
        public var explanation: String
        /// Changes the model suggested that failed validation (unknown id, wrong type…).
        public var rejected: [String]
    }

    public let provider: any AIProvider
    public let catalog: SettingCatalog

    public init(provider: any AIProvider, catalog: SettingCatalog = .bundled) {
        self.provider = provider
        self.catalog = catalog
    }

    static let instructions = """
    你是 AIME 输入法的配置助手。用户用自然语言描述想要的输入法行为，你只能从给定的设置目录中挑选设置项并给出新值。
    严格只输出一个 JSON 对象，不要输出其他文字：
    {"changes":[{"id":"<设置 id>","value":<新值>}],"explanation":"<一句中文说明>"}
    规则：id 必须来自目录；bool 用 true/false；int/double 用数字并遵守 min/max；enum 只能用给出的取值；
    color 用 "0xAARRGGBB" 字符串；无法满足的需求写进 explanation，不要编造 id。
    """

    /// Compact catalog listing: id | type | title | constraints | current value.
    func catalogDigest(current: (SettingCatalog.Setting) -> ConfigValue?) -> String {
        catalog.settings.filter { $0.type != .custom }.map { setting in
            var parts = [setting.id, setting.type.rawValue, setting.title]
            if let options = setting.options { parts.append("取值: " + options.compactMap { $0.value.stringValue }.joined(separator: "/")) }
            if let min = setting.min { parts.append("min \(min)") }
            if let max = setting.max { parts.append("max \(max)") }
            if let value = current(setting)?.stringValue { parts.append("当前 \(value)") }
            return parts.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    public func propose(_ request: String, current: @Sendable (SettingCatalog.Setting) -> ConfigValue?) async throws -> Result {
        let prompt = "设置目录：\n\(catalogDigest(current: current))\n\n用户需求：\(request)"
        let reply = try await provider.complete(instructions: Self.instructions, prompt: prompt)
        return try parse(reply, current: current)
    }

    func parse(_ reply: String, current: (SettingCatalog.Setting) -> ConfigValue?) throws -> Result {
        guard let data = JSONExtractor.firstJSON(in: reply),
              let object = try? JSONDecoder().decode(Reply.self, from: data)
        else { throw AIError.badResponse(String(reply.prefix(120))) }

        var proposals: [Proposal] = []
        var rejected: [String] = []
        for change in object.changes ?? [] {
            guard let setting = catalog.setting(change.id), setting.type != .custom else {
                rejected.append("\(change.id)：目录中没有这个设置")
                continue
            }
            guard let value = Self.validate(change.value, for: setting) else {
                rejected.append("\(setting.title)：取值 \(change.value.stringValue ?? "?") 不合法")
                continue
            }
            if current(setting) == value { continue }
            proposals.append(Proposal(setting: setting, current: current(setting), proposed: value))
        }
        return Result(proposals: proposals, explanation: object.explanation ?? "", rejected: rejected)
    }

    private struct Reply: Decodable {
        struct Change: Decodable { let id: String; let value: ConfigValue }
        let changes: [Change]?
        let explanation: String?
    }

    /// Coerces and checks a proposed value against the setting's declared type.
    static func validate(_ value: ConfigValue, for setting: SettingCatalog.Setting) -> ConfigValue? {
        switch setting.type {
        case .bool:
            if let bool = value.boolValue { return .bool(bool) }
            if let text = value.stringValue?.lowercased(), ["true", "false"].contains(text) { return .bool(text == "true") }
            return nil
        case .int, .double:
            guard let number = value.doubleValue ?? value.stringValue.flatMap(Double.init) else { return nil }
            if let min = setting.min, number < min { return nil }
            if let max = setting.max, number > max { return nil }
            return setting.type == .int ? .int(Int(number.rounded())) : .double(number)
        case .enum:
            guard let options = setting.options, let match = options.first(where: { $0.value == value || $0.value.stringValue == value.stringValue })
            else { return nil }
            return match.value
        case .color:
            guard let text = value.stringValue, text.range(of: #"^0x[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$"#, options: .regularExpression) != nil
            else { return nil }
            return .string(text)
        case .string, .font, .hotkey, .gramModel:
            guard let text = value.stringValue, !text.isEmpty, text.count < 120 else { return nil }
            return .string(text)
        case .stringList, .hotkeyList, .switchList:
            guard let list = value.listValue else { return nil }
            let strings = list.compactMap(\.stringValue)
            return strings.count == list.count ? .list(strings.map(ConfigValue.string)) : nil
        case .custom:
            return nil
        }
    }
}
