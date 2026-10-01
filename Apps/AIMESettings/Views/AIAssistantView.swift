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
                            model.updateFeatures { $0.aiActions.removeAll { $0.id == action.id } }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    CommitTextField(value: action.prompt, placeholder: "提示词：告诉 AI 怎么处理这段文字", maxWidth: .infinity) { prompt in
                        model.updateFeatures { features in
                            if let index = features.aiActions.firstIndex(where: { $0.id == action.id }) { features.aiActions[index].prompt = prompt }
                        }
                    }
                    .frame(maxWidth: .infinity)
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

struct AIAssistantView: View {
    @Environment(SettingsModel.self) private var model
    @AppStorage("ai.provider") private var providerID = "apple"
    @AppStorage("ai.baseURL") private var baseURL = "https://api.openai.com/v1"
    @AppStorage("ai.model") private var modelName = "gpt-5-mini"
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
            check = .passed(try await OpenAICompatibleProvider(baseURL: url, model: modelName).verify())
        } catch let error as AIError {
            check = .failed(error.description)
        } catch {
            check = .failed(error.localizedDescription)
        }
    }

    private var provider: any AIProvider {
        if providerID == "openai", let url = URL(string: baseURL) {
            return OpenAICompatibleProvider(baseURL: url, model: modelName)
        }
        return FoundationModelsProvider()
    }

    var body: some View {
        Form {
            Section { PaneHeader(title: "AI 助手", subtitle: "用一句话修改配置、从文章里挑出新词。可选功能，默认使用本机端侧模型。", symbol: "wand.and.sparkles") }


            Section {
                Label {
                    Text("AI 只会看到：你在这里输入或粘贴的文字，你主动执行动作时的那段文字（草稿、选中的文字或刚打的字），以及公开的设置目录。不执行动作时，你打的字不会发给 AI；高频词统计和词频数据永远不会。")
                } icon: { Image(systemName: "lock.shield").foregroundStyle(Theme.success) }
                .font(.callout)
            }

            Section("模型") {
                Picker("提供方", selection: $providerID) {
                    Text("Apple 端侧模型（本机，推荐）").tag("apple")
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
            .onChange(of: [baseURL, modelName]) { check = .idle }
            .onChange(of: [providerID, baseURL, modelName], initial: true) {
                // The input method reads the provider from aime/features.json.
                model.updateFeatures {
                    $0.aiProvider = providerID
                    $0.aiBaseURL = baseURL
                    $0.aiModel = modelName
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
                        Text("按 ⌃⌥P，或长按呼出键打开快捷菜单后按空格，进入「AI 处理」，再按数字选择动作：1 翻译、2 润色，之后是你的自定义动作。正在选字时执行，会先把高亮的候选上屏再处理它；否则处理对象依次是：输入图层里的草稿、你选中的文字、刚在这个输入框里打的字。结果列在候选窗里，回车或数字应用，C 复制，Esc 取消；替换前会核对原文没有变化。")
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
                            Text(term.code).font(.caption.monospaced()).foregroundStyle(.secondary)
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
                                for term in terms where chosen.contains(term.id) { phrases.add(.init(text: term.text, code: term.code)) }
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
