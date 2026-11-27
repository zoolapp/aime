import AIMEAI
import AIMECore
import SwiftUI

/// The user's own AI actions: a name for the menu and a prompt. Presets fill both in.
private struct CustomActionsSection: View {
    @Environment(SettingsModel.self) private var model

    static let presets: [(name: String, prompt: String)] = [
        ("更口语", "把这段话改得更口语、自然，像平时聊天那样，保持原意。"),
        ("更礼貌", "把这段话改得更礼貌、得体，适合发给同事或客户，保持原意。"),
        ("总结成一句", "用一句话概括这段话的要点。"),
        ("修正错别字", "只修正错别字、标点和明显的语病，不要改动措辞和语气。"),
        ("扩写", "在保持原意的前提下，把这段话扩写得更完整、更有条理。"),
    ]

    var body: some View {
        Section {
            ForEach(model.features.aiActions) { action in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        CommitTextField(value: action.name, placeholder: "名称（显示在快捷菜单里）") { name in
                            model.updateFeatures { features in
                                if let index = features.aiActions.firstIndex(where: { $0.id == action.id }) { features.aiActions[index].name = name }
                            }
                        }
                        .frame(width: 220)
                        Spacer()
                        Button(role: .destructive) {
                            model.updateFeatures {
                                $0.aiActions.removeAll { $0.id == action.id }
                                $0.setActionHotkey(nil, for: action.id.uuidString)
                            }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    ActionPromptEditor(value: action.prompt) { prompt in
                        model.updateFeatures { features in
                            if let index = features.aiActions.firstIndex(where: { $0.id == action.id }) { features.aiActions[index].prompt = prompt }
                        }
                    }
                }
            }
            Menu {
                ForEach(Self.presets, id: \.name) { preset in
                    Button(preset.name) { model.updateFeatures { $0.aiActions.append(.init(name: preset.name, prompt: preset.prompt)) } }
                }
                Divider()
                Button("空白动作…") { model.updateFeatures { $0.aiActions.append(.init(name: "新动作", prompt: "")) } }
            } label: {
                Label("添加动作", systemImage: "plus")
            }
            .fixedSize()
        } header: {
            Text("自定义动作")
        } footer: {
            Text("自定义动作会出现在快捷菜单的「AI 处理」里，排在「翻译」「润色」之后，用数字键选择。")
        }
    }
}

/// One shortcut per action, so an action runs without going through the AI menu.
private struct ActionHotkeysSection: View {
    private typealias Key = AIMEFeatures.ActionHotkey
    @Environment(SettingsModel.self) private var model
    @State private var warning: String?

    var body: some View {
        Section {
            let features = model.features
            row("翻译", key: Key.translate, features: features)
            row("润色", key: Key.polish, features: features)
            row("简繁转换", key: Key.convertScript, features: features)
            ForEach(features.aiActions) { action in
                row(action.name.isEmpty ? "未命名动作" : action.name, key: action.id.uuidString, features: features)
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
        } header: {
            Text("动作快捷键")
        } footer: {
            Text("按下快捷键直接执行该动作，不用先打开菜单再选；处理对象与 ⌃⌥P 相同。需要包含 ⌃、⌥ 或 ⌘（或使用 F1–F12），一个快捷键只对应一个动作。")
        }
    }

    private func row(_ title: String, key: String, features: AIMEFeatures) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                KeyRecorder(value: features.actionHotkeys[key] ?? "") { rime in
                    guard AIMEFeatures.ActionHotkey.isUsable(rime) else {
                        warning = AIMEFeatures.ActionHotkey.reserved.contains(rime)
                            ? "\(HotkeyFormatter.display(rime)) 已用于打开菜单，请换一个。"
                            : "\(HotkeyFormatter.display(rime)) 会被当作打字，请加上 ⌃、⌥ 或 ⌘。"
                        return
                    }
                    warning = nil
                    model.updateFeatures { $0.setActionHotkey(rime, for: key) }
                }
                if features.actionHotkeys[key] != nil {
                    Button {
                        model.updateFeatures { $0.setActionHotkey(nil, for: key) }
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("清除快捷键")
                }
            }
        }
    }
}

private struct ActionPromptEditor: View {
    let value: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $draft)
            .font(.body)
            .focused($focused)
            .scrollContentBackground(.hidden)
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("提示词：告诉 AI 怎么处理这段文字")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 7)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            // A bare TextEditor has no edge: give it the field look of the text boxes around it.
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
            .accessibilityLabel("提示词")
            .onChange(of: value, initial: true) { _, new in
                if !focused { draft = new }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { saveChanges() }
            }
            .onDisappear(perform: saveChanges)
    }

    private func saveChanges() {
        if draft != value { commit(draft) }
    }
}

struct AIAssistantView: View {
    @Environment(SettingsModel.self) private var model
    @AppStorage("ai.provider") private var providerID = "apple"
    @AppStorage("ai.baseURL") private var baseURL = "https://api.openai.com/v1"
    @AppStorage("ai.model") private var modelName = "gpt-5-mini"
    /// Extra JSON object merged into every chat/completions request body.
    @AppStorage("ai.extraJSON") private var extraJSON = ""
    @State private var apiKey = ""
    @State private var availability: AIAvailability?
    /// Outcome of the last connection check (OpenAI-compatible endpoint).
    @State private var check: ConnectionCheck = .idle

    enum ConnectionCheck: Equatable {
        case idle, running
        case passed(OpenAICompatibleProvider.Verification)
        case failed(String)
    }

    @State private var request = ""
    @State private var working = false
    @State private var result: ConfigAssistant.Result?

    @State private var sourceText = ""
    @State private var terms: [VocabularyExtractor.Term] = []
    @State private var chosen = Set<String>()
    @State private var message: String?

    private var hasSavedKey: Bool { _ = availability; return CredentialStore(account: "openai-compatible").read() != nil }

    /// Result of the last check, in words: which model answered and how fast, or why not.
    @ViewBuilder private var connectionStatus: some View {
        switch check {
        case .running:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在验证…").foregroundStyle(.secondary) }
        case let .passed(result):
            Label("可用 · \(result.model) · \(result.seconds.formatted(.number.precision(.fractionLength(1)))) 秒", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
                .help("模型回复：\(result.reply)")
        case let .failed(reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        case .idle:
            Text(hasSavedKey ? "已保存 Key，尚未验证" : "尚未配置 API Key").foregroundStyle(.secondary)
        }
    }

    /// Each vendor's way of turning the model's thinking off. One click merges
    /// the fields into the custom-JSON box; nothing else is touched.
    struct ThinkingPreset {
        var title: String
        var hint: String
        var fields: [String: Any]
    }

    static let thinkingPresets: [ThinkingPreset] = [
        .init(title: "DeepSeek", hint: "DeepSeek：官方 thinking 参数", fields: ["thinking": ["type": "disabled"]]),
        .init(title: "Gemini", hint: "Gemini（OpenAI 兼容接口）", fields: ["reasoning_effort": "none"]),
        .init(title: "GLM", hint: "智谱 GLM", fields: ["thinking": ["type": "disabled"]]),
        .init(title: "Kimi", hint: "Kimi / Moonshot：官方 thinking 参数", fields: ["thinking": ["type": "disabled"]]),
        .init(title: "OpenAI", hint: "OpenAI：仅 gpt-5.1 及之后的推理模型支持 none；更早的推理模型最低只到 minimal，非推理模型带此字段会报错", fields: ["reasoning_effort": "none"]),
        .init(title: "OpenRouter", hint: "OpenRouter 统一参数，适用于 Claude 等模型", fields: ["reasoning": ["effort": "none"]]),
        .init(title: "Qwen", hint: "通义 Qwen / vLLM 部署", fields: ["enable_thinking": false]),
    ]

    /// Parses the box as a JSON object. nil = empty or not a valid JSON object.
    private var extraJSONObject: [String: Any]? {
        let trimmed = extraJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Live verdict under the box: field count when valid, a hint when not.
    @ViewBuilder private var extraJSONStatus: some View {
        let trimmed = extraJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            EmptyView()
        } else if let object = extraJSONObject {
            Label("JSON 有效，将合并 \(object.keys.filter { !OpenAICompatibleProvider.reservedKeys.contains($0) }.count) 个字段", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
        } else {
            Label("不是合法的 JSON 对象，不会被发送", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
        }
    }

    /// Merges a preset's fields into the box. Merges into the existing object
    /// when it parses; non-empty invalid JSON is left alone so the user does
    /// not lose a half-written object.
    private func mergeFields(_ fields: [String: Any]) {
        let trimmed = extraJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, extraJSONObject == nil { return }
        var object = extraJSONObject ?? [:]
        for (key, value) in fields { object[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        extraJSON = text
    }

    private func saveKeyAndVerify() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        CredentialStore(account: "openai-compatible").write(key)
        apiKey = ""
        Task {
            availability = await provider.availability()
            await verify()
        }
    }

    /// One small request with the saved address, model and key.
    private func verify() async {
        guard let url = URL(string: baseURL), url.scheme?.hasPrefix("http") == true else {
            check = .failed("接口地址不是有效的网址")
            return
        }
        check = .running
        do {
            check = .passed(try await OpenAICompatibleProvider(baseURL: url, model: modelName, extraFieldsJSON: extraJSON).verify())
        } catch let error as AIError {
            check = .failed(error.description)
        } catch {
            check = .failed(error.localizedDescription)
        }
    }

    private var provider: any AIProvider {
        if providerID == "openai", let url = URL(string: baseURL) {
            return OpenAICompatibleProvider(baseURL: url, model: modelName, extraFieldsJSON: extraJSON)
        }
        return FoundationModelsProvider()
    }

    /// FoundationModels ships with macOS 26; older systems need a custom endpoint.
    private var onDeviceModelSupported: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    var body: some View {
        Form {
            Section {
                PaneHeader(title: "AI 助手",
                           subtitle: onDeviceModelSupported
                               ? "用一句话修改配置、从文章里挑出新词。可选功能，默认使用本机端侧模型。"
                               : "用一句话修改配置、从文章里挑出新词。可选功能；本机端侧模型需要 macOS 26，可改用自备接口。",
                           symbol: "wand.and.sparkles")
            }


            Section {
                Label {
                    Text("AI 只会看到：你在这里输入或粘贴的文字，你主动执行动作时的那段文字（草稿、选中的文字或刚打的字），以及公开的设置目录。不执行动作时，你打的字不会发给 AI；高频词统计和词频数据永远不会。")
                } icon: { Image(systemName: "lock.shield").foregroundStyle(Theme.success) }
                .font(.callout)
            }

            Section("模型") {
                Picker("提供方", selection: $providerID) {
                    Text(onDeviceModelSupported ? "Apple 端侧模型（本机，推荐）" : "Apple 端侧模型（需要 macOS 26）").tag("apple")
                    Text("OpenAI 兼容接口（自备 Key）").tag("openai")
                }
                if providerID == "openai" {
                    LabeledContent("接口地址") {
                        TextField("", text: $baseURL, prompt: Text("https://api.openai.com/v1"))
                            .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 320)
                    }
                    LabeledContent("模型") {
                        TextField("", text: $modelName, prompt: Text("gpt-5-mini"))
                            .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 320)
                    }
                    HStack {
                        Text("API Key").frame(maxWidth: .infinity, alignment: .leading)
                        SecureField("", text: $apiKey, prompt: Text(hasSavedKey ? "已保存，输入新的可替换" : "粘贴 API Key"))
                            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 250)
                            .onSubmit(saveKeyAndVerify)
                        Button("保存并验证", action: saveKeyAndVerify)
                            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("自定义请求体")
                        Text("顶层字段合并进每次请求的 body，可覆盖 temperature、max_tokens 等；model、messages、stream 由程序控制。")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $extraJSON)
                            .font(.caption.monospaced())
                            .frame(minHeight: 60, maxHeight: 140)
                            .overlay(alignment: .topLeading) {
                                if extraJSON.isEmpty {
                                    Text("{\"thinking\": {\"type\": \"disabled\"}}")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8).padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }
                        HStack(spacing: 6) {
                            extraJSONStatus
                        }
                        .font(.caption)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("关闭思考").foregroundStyle(.secondary)
                            ForEach(Self.thinkingPresets, id: \.title) { preset in
                                Button(preset.title) { mergeFields(preset.fields) }
                                    .controlSize(.small)
                                    .help(preset.hint)
                            }
                        }
                        Text("点按钮把该厂商官方文档里的关闭思考参数合并进上方 JSON；OpenAI 仅推理模型适用。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                LabeledContent("状态") {
                    if providerID == "openai" {
                        HStack(spacing: 10) {
                            connectionStatus
                            Button("验证") { Task { await verify() } }
                                .disabled(check == .running || !hasSavedKey)
                        }
                    } else {
                        switch availability {
                        case .available: Label("可用", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                        case let .unavailable(reason): Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                        case nil: ProgressView().controlSize(.small)
                        }
                    }
                }
            }
            .task(id: providerID) { availability = await provider.availability() }
            // Address or model changed: the previous check no longer says anything.
            .onChange(of: [baseURL, modelName, extraJSON]) { check = .idle }
            .onChange(of: [providerID, baseURL, modelName, extraJSON], initial: true) {
                // The input method reads the provider from aime/features.json.
                model.updateFeatures {
                    $0.aiProvider = providerID
                    $0.aiBaseURL = baseURL
                    $0.aiModel = modelName
                    $0.aiExtraJSON = extraJSON
                }
            }

            Section {
                let features = model.features
                Toggle(isOn: Binding(get: { features.aiPolish }, set: { on in model.updateFeatures { $0.aiPolish = on } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("AI 处理：翻译、润色、自定义")
                            Text("⌃⌥P").font(.caption.monospaced()).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        }
                        Text("按 ⌃⌥P，或长按呼出键打开快捷菜单后按空格，进入「AI 处理」，再按数字选择动作：1 翻译、2 润色，之后是你的自定义动作；也可以在下方「动作快捷键」给常用动作单独设快捷键。"
                             + "正在选字时执行，会先把高亮的候选上屏再处理它；否则处理对象依次是：输入图层里的草稿、你选中的文字、刚在这个输入框里打的字。结果列在候选窗里，回车或数字应用，C 复制，Esc 取消；替换前会核对原文没有变化。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if features.aiPolish, providerID == "openai" {
                    Toggle(isOn: Binding(get: { features.aiRemoteAllowed }, set: { on in model.updateFeatures { $0.aiRemoteAllowed = on } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("允许把要处理的文字发送到自备接口")
                            Text("执行动作时会把那段文字发送到 \(URL(string: baseURL)?.host() ?? baseURL)（模型 \(modelName)）。关闭后只能使用 Apple 端侧模型。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if features.aiPolish, providerID == "apple", availability?.isAvailable == false {
                    Label("Apple 端侧模型当前不可用，按 ⌃⌥P 会提示原因；可改用自备接口。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
            } header: {
                Text("AI 动作")
            }

            if model.features.aiPolish {
                CustomActionsSection()
                ActionHotkeysSection()
            }

            Section {
                let features = model.features
                Toggle(isOn: Binding(get: { features.draftLayer }, set: { on in model.updateFeatures { $0.draftLayer = on } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("输入图层")
                        Text("打出的字先停在光标处（带下划线），不立刻进入应用：回车上屏，⌫ 修改，按 ⌃⌥P 选择翻译、润色等动作后再上屏。终端、代码编辑器、启动器和密码管理器中不启用。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if features.draftLayer {
                    LabeledContent {
                        Picker("", selection: Binding(get: { features.draftAutoCommit }, set: { value in model.updateFeatures { $0.draftAutoCommit = value } })) {
                            Text("不自动上屏").tag(0)
                            Text("3 秒后").tag(3)
                            Text("5 秒后").tag(5)
                        }
                        .labelsHidden().fixedSize()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动上屏")
                            Text("停止打字这么久之后，草稿自动进入应用。正在选词、选择动作或等待 AI 结果时不计时。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if features.aiPolish {
                        LabeledContent {
                            Picker("", selection: Binding(get: { features.activeDraftAutoAction ?? "" },
                                                          set: { value in model.updateFeatures { $0.draftAutoAction = value } })) {
                                Text("无").tag("")
                                Text("翻译").tag(AIMEFeatures.ActionHotkey.translate)
                                Text("润色").tag(AIMEFeatures.ActionHotkey.polish)
                                ForEach(features.aiActions) { action in
                                    Text(action.name.isEmpty ? "未命名动作" : action.name).tag(action.id.uuidString)
                                }
                            }
                            .labelsHidden().fixedSize()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("上屏前执行动作")
                                Text("按触发键或到了自动上屏的时间，先对草稿执行这个动作，结果列出来由你选：回车用结果上屏，Esc 按原文上屏。"
                                     + "开启后，停止打字到时间就会把草稿交给所选模型，不需要再按键。")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if features.activeDraftAutoAction != nil {
                            LabeledContent {
                                Picker("", selection: Binding(get: { features.draftAutoActionKey },
                                                              set: { value in model.updateFeatures { $0.draftAutoActionKey = value } })) {
                                    Text("回车").tag(AIMEFeatures.DraftActionKey.return)
                                    Text("空格").tag(AIMEFeatures.DraftActionKey.space)
                                }
                                .labelsHidden().fixedSize()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("触发键")
                                    Text("回车：回车执行动作，Esc 按原文上屏。空格：空格执行动作，回车照常按原文上屏；草稿以英文字母或数字结尾时，空格仍然输入空格。")
                                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("输入图层")
            }

            Section("用一句话修改配置") {
                TextField("例如：候选改成 7 个，开启 zh/z 模糊音", text: $request, axis: .vertical)
                    .lineLimit(2...4)
                HStack {
                    Spacer()
                    Button {
                        Task { await propose() }
                    } label: { working ? AnyView(ProgressView().controlSize(.small)) : AnyView(Label("生成修改", systemImage: "sparkles")) }
                        .disabled(request.isEmpty || working || availability?.isAvailable != true)
                }
                if let result {
                    if !result.explanation.isEmpty { Text(result.explanation).font(.callout).foregroundStyle(.secondary) }
                    ForEach(result.proposals) { proposal in
                        HStack {
                            Text(proposal.setting.title)
                            Spacer()
                            Text(proposal.current?.stringValue ?? "—").foregroundStyle(.secondary).strikethrough()
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                            Text(proposal.proposed.stringValue ?? "").fontWeight(.medium)
                        }
                    }
                    ForEach(result.rejected, id: \.self) { Label($0, systemImage: "xmark.circle").font(.caption).foregroundStyle(Theme.warning) }
                    if !result.proposals.isEmpty {
                        HStack {
                            Spacer()
                            Button("放弃") { self.result = nil }
                            Button("应用 \(result.proposals.count) 项修改") {
                                for proposal in result.proposals { model.set(proposal.proposed, for: proposal.setting) }
                                self.result = nil
                                request = ""
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }

            Section("从文本中发现新词") {
                TextEditor(text: $sourceText)
                    .font(.body)
                    .frame(minHeight: 90)
                    .overlay(alignment: .topLeading) {
                        if sourceText.isEmpty { Text("粘贴一段文章、会议纪要或聊天记录…").foregroundStyle(.tertiary).padding(6).allowsHitTesting(false) }
                    }
                HStack {
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button { Task { await extract() } } label: { Label("找出新词", systemImage: "text.magnifyingglass") }
                        .disabled(sourceText.isEmpty || working || availability?.isAvailable != true)
                }
                ForEach(terms) { term in
                    Toggle(isOn: Binding(get: { chosen.contains(term.id) }, set: { on in
                        if on { chosen.insert(term.id) } else { chosen.remove(term.id) }
                    })) {
                        HStack {
                            Text(term.text)
                            Text(model.phraseCode(term.text) ?? term.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                            if !term.note.isEmpty { Text(term.note).font(.caption2).foregroundStyle(.tertiary) }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                if !terms.isEmpty {
                    HStack {
                        Spacer()
                        Button("加入自定义短语（\(chosen.count)）") {
                            model.updatePhrases { phrases in
                                for term in terms where chosen.contains(term.id) { phrases.add(.init(text: term.text, code: model.phraseCode(term.text) ?? term.code)) }
                            }
                            model.savePhrases()
                            message = "已加入 \(chosen.count) 个词，正在自动应用"
                            terms = []
                            chosen = []
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(chosen.isEmpty)
                    }
                }
            }
        }
        .formStyle(.cards)
    }

    private func propose() async {
        working = true
        defer { working = false }
        let store = model.store
        do {
            result = try await ConfigAssistant(provider: provider, catalog: model.catalog).propose(request) { store.value(for: $0) }
        } catch {
            model.perform { throw error }
        }
    }

    private func extract() async {
        working = true
        defer { working = false }
        do {
            let existing = Set(model.phrases.phrases.map(\.text))
            terms = try await VocabularyExtractor(provider: provider).extract(from: sourceText, excluding: existing)
            chosen = Set(terms.map(\.id))
            message = terms.isEmpty ? "没有找到新词" : nil
        } catch {
            model.perform { throw error }
        }
    }
}
