import AIMECore
import AIMEPanel
import AppKit
import SwiftUI

/// First-run guide: enable the input method, pick 全拼 / 双拼, three habits, the optional
/// smart features, then try it out on sample phrases. Every step starts from the current
/// configuration, and only what the user changed is written.
struct OnboardingView: View {
    @Environment(SettingsModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .welcome
    @State private var forward = true
    @State private var choices = Choices()
    @State private var loaded = false
    @State private var applying = false
    let finish: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, enable, scheme, habits, smart, practice, done

        var title: String {
            switch self {
            case .welcome: ""
            case .enable: "启用艾么输入法"
            case .scheme: "你平时怎么打字？"
            case .habits: "候选词怎么显示"
            case .smart: "智能功能"
            case .practice: "试一试"
            case .done: "准备好了"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome: ""
            case .enable: "在系统设置里添加一次，之后用 ⌃空格 或菜单栏切换。"
            case .scheme: "选你习惯的方式，之后随时可以在「输入方案」里改。"
            case .habits: "三个最常调整的选项，下面是实时预览。"
            case .smart: "都是可选的，之后可以随时在设置里改。数据只留在你的 Mac 上。"
            case .practice: "切换到艾么输入法，在下面的输入框里跟着做。"
            case .done: "设置都已生效。常用的操作记在这里。"
            }
        }
    }

    /// What the guide will write. Seeded from the current configuration.
    struct Choices: Equatable {
        var schema = "rime_ice"
        var pageSize = 7
        var layout = "linear"
        var traditional = false
        var aiActions = false
        var stats = false
        var smartApps = true
        var samplePhrases = true
        var importSquirrel = false
    }

    /// Sample phrases the practice step teaches with (added to the phrase table in use).
    static let samples: [(code: String, text: String, title: String)] = [
        ("am", "艾么输入法", "产品名"),
        ("gw", "https://aime.zool.app", "官网"),
        ("yx", "hello@zool.app", "邮箱"),
    ]

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            AmbientGlow().opacity(step == .welcome || step == .done ? 1 : 0.35)
            VStack(spacing: 0) {
                if step != .welcome { progress.padding(.top, 44) } // clear of the window controls
                ZStack {
                    content(for: step)
                        .id(step)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                }
                .frame(maxWidth: 640, maxHeight: .infinity)
                .clipped()
                if step != .welcome { footer.padding(.bottom, 26) }
            }
            .padding(.horizontal, 32)
        }
        // A sheet does not inherit the window's tint.
        .tint(Theme.accent)
        .onAppear {
            load()
            // Screenshot automation: `--onboarding-step=<n>` opens a given step. One token: a bare
            // number would make AppKit treat it as a document to open and skip the window.
            if let raw = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--onboarding-step=") })?.split(separator: "=").last,
               let n = Int(raw), let target = Step(rawValue: n) { step = target }
        }
    }

    // MARK: - Chrome

    private var progress: some View {
        let steps = Step.allCases.filter { $0 != .welcome }
        return HStack(spacing: 6) {
            ForEach(steps, id: \.self) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(0.12)))
                    .frame(width: item == step ? 26 : 14, height: 5)
            }
        }
        .animation(.snappy, value: step)
        .accessibilityLabel("第 \(step.rawValue) 步，共 \(steps.count) 步")
    }

    private var footer: some View {
        HStack {
            if step != .done {
                Button("返回") { go(-1) }.buttonStyle(.borderless).disabled(step == .enable)
            }
            Spacer()
            if step == .enable, !model.isInputSourceEnabled {
                Button("稍后再说") { go(1) }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            if step == .practice { Button("跳过") { go(1) }.buttonStyle(.borderless).foregroundStyle(.secondary) }
            Button(primaryTitle) { primaryAction() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(applying)
        }
        .frame(maxWidth: 640)
    }

    private var primaryTitle: String {
        switch step {
        case .smart: applying ? "正在应用…" : "应用并继续"
        case .done: "开始使用"
        default: "继续"
        }
    }

    private func primaryAction() {
        switch step {
        case .smart: Task { await apply() }
        case .done: finish()
        default: go(1)
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.5, bounce: 0.14)) { step = next }
    }

    @ViewBuilder private func content(for step: Step) -> some View {
        switch step {
        case .welcome: WelcomeStep { go(1) }
        default:
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(step.title).font(.system(size: 26, weight: .bold))
                    Text(step.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Group {
                    switch step {
                    case .enable: EnableStep()
                    case .scheme: SchemeStep(choices: $choices)
                    case .habits: HabitsStep(choices: $choices)
                    case .smart: SmartStep(choices: $choices)
                    case .practice: PracticeStep(samples: choices.samplePhrases ? Self.samples : [])
                    default: DoneStep()
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Reading and writing

    private func load() {
        guard !loaded else { return }
        loaded = true
        var current = Choices()
        current.schema = model.enabledSchemas.first ?? "rime_ice"
        if let setting = model.setting("menu.page_size"), case let .int(value)? = model.value(setting) { current.pageSize = value }
        if let setting = model.setting("appearance.candidate_list_layout"), case let .string(value)? = model.value(setting) { current.layout = value }
        let features = model.features
        current.traditional = features.traditional
        current.aiActions = features.aiPolish
        current.stats = features.usageStats
        current.importSquirrel = model.squirrelDirExists && !model.hasImported
        choices = current
        initial = current
    }

    @State private var initial = Choices()

    /// Writes what changed, then lets auto-deploy apply it while the user practises.
    private func apply() async {
        applying = true
        defer { applying = false }
        if choices.importSquirrel, !model.hasImported { await model.importSquirrel() }
        if choices.schema != initial.schema {
            model.setEnabledSchemas([choices.schema] + model.enabledSchemas.filter { $0 != choices.schema })
        }
        if choices.pageSize != initial.pageSize, let setting = model.setting("menu.page_size") {
            model.set(.int(choices.pageSize), for: setting)
        }
        if choices.layout != initial.layout, let setting = model.setting("appearance.candidate_list_layout") {
            model.set(.string(choices.layout), for: setting)
        }
        let wanted = choices
        model.updateFeatures {
            $0.traditional = wanted.traditional
            $0.aiPolish = wanted.aiActions
            $0.usageStats = wanted.stats
        }
        if choices.samplePhrases {
            let existing = Set(model.phrases.phrases.map(\.code))
            let missing = Self.samples.filter { !existing.contains($0.code) }
            if !missing.isEmpty {
                model.updatePhrases { phrases in for sample in missing { _ = phrases.add(.init(text: sample.text, code: sample.code)) } }
                model.savePhrases()
            }
        }
        if choices.smartApps {
            await model.scanInstalledApps()
            model.applyAppSuggestions()
            model.dismissAppScan()
        }
        go(1)
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    let start: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            ZStack {
                GlowRing(size: 132, lineWidth: 3, blur: 14).opacity(shown ? 1 : 0)
                Image("BrandSquare")
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                    .scaleEffect(shown ? 1 : 0.86)
            }
            VStack(spacing: 10) {
                Text("欢迎使用艾么输入法").font(.system(size: 30, weight: .bold))
                Text("RIME 的速度与可定制，加上 AI 的翻译与润色。花一分钟，按你的习惯设置好。")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            Button(action: start) {
                Text("开始设置").frame(width: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .opacity(shown ? 1 : 0)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.9, bounce: 0.2).delay(0.1)) { shown = true }
        }
    }
}

private struct EnableStep: View {
    @Environment(SettingsModel.self) private var model
    @State private var tick = 0

    var body: some View {
        let enabled = { _ = tick; return model.isInputSourceEnabled }()
        VStack(alignment: .leading, spacing: 16) {
            EnableStatusCard(done: enabled,
                       title: enabled ? "已添加到输入法" : "还没有添加",
                       detail: enabled ? "可以用 ⌃空格 或菜单栏的输入法图标切换到艾么输入法。"
                                       : "打开 系统设置 › 键盘 › 输入法 › 编辑…，点左下角 +，在「简体中文」里选「艾么输入法」。")
            if !enabled {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
                } label: {
                    Label("打开键盘设置", systemImage: "keyboard")
                }
                .controlSize(.large)
                Text("添加后这里会自动变成已完成。第一次添加后，个别应用可能需要重新打开。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        // The system has no change notification for enabled input sources: look again every second.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick += 1
            }
        }
        .animation(.snappy, value: enabled)
    }
}

private struct SchemeStep: View {
    @Environment(SettingsModel.self) private var model
    @Binding var choices: OnboardingView.Choices

    private static let doublePinyin: [(id: String, title: String)] = [
        ("double_pinyin_flypy", "小鹤双拼"), ("double_pinyin", "自然码"), ("double_pinyin_mspy", "微软双拼"),
        ("double_pinyin_sogou", "搜狗双拼"), ("double_pinyin_abc", "智能 ABC"), ("double_pinyin_ziguang", "紫光双拼"),
        ("double_pinyin_jiajia", "拼音加加"),
    ]

    var body: some View {
        let available = Set(model.availableSchemas.map(\.id))
        let variants = Self.doublePinyin.filter { available.contains($0.id) }
        let isDouble = choices.schema.hasPrefix("double_pinyin")
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ChoiceCard(selected: !isDouble, symbol: "character.textbox", title: "全拼", detail: "输入完整拼音，例如 nihao") {
                    choices.schema = "rime_ice"
                }
                ChoiceCard(selected: isDouble, symbol: "keyboard", title: "双拼", detail: "每个字两键，例如小鹤双拼 nihk") {
                    if !isDouble { choices.schema = variants.first?.id ?? "double_pinyin_flypy" }
                }
            }
            if isDouble {
                VStack(alignment: .leading, spacing: 8) {
                    Text("双拼方案").font(.subheadline.weight(.semibold))
                    FlowChips(items: variants, selected: choices.schema) { choices.schema = $0 }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if model.squirrelDirExists, !model.hasImported {
                Toggle(isOn: $choices.importSquirrel) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("导入鼠须管的配置")
                        Text("发现 ~/Library/Rime：复制你的方案、短语和词频快照，原目录只读、不会改动。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            }
        }
        .animation(.snappy, value: isDouble)
    }
}

private struct HabitsStep: View {
    @Environment(SettingsModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Binding var choices: OnboardingView.Choices

    var body: some View {
        // Controls in one row, the preview below at full width: a horizontal row of nine
        // candidates needs the room (side by side it pushed the controls off the sheet).
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 28) {
                row("排列") {
                    Picker("", selection: $choices.layout) {
                        Text("横排").tag("linear")
                        Text("竖排").tag("stacked")
                    }
                }
                row("每页候选") {
                    Picker("", selection: $choices.pageSize) {
                        ForEach([5, 7, 9], id: \.self) { Text("\($0) 个").tag($0) }
                    }
                }
                row("默认输出") {
                    Picker("", selection: $choices.traditional) {
                        Text("简体").tag(false)
                        Text("繁体").tag(true)
                    }
                }
                Spacer(minLength: 0)
            }
            preview
            Text("字体、配色等更多外观在「外观」里调整。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            content().pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }

    private var preview: some View {
        var theme = model.theme(dark: colorScheme == .dark)
        theme.layout = choices.layout == "stacked" ? .stacked : .linear
        // Preview size: nine stacked candidates must fit the card.
        theme.fontPoint = min(theme.fontPoint, 15)
        theme.labelFontPoint = min(theme.labelFontPoint, 12)
        theme.commentFontPoint = min(theme.commentFontPoint, 12)
        theme.lineSpacing = min(theme.lineSpacing, 3)
        let words = ["你好", "拟好", "泥壕", "尼豪", "逆号", "你", "呢", "妮", "倪"]
        let texts = words.prefix(choices.pageSize).map { choices.traditional ? ScriptConverter.traditional($0) : $0 }
        let state = PanelState(preedit: "ni hao", preeditSelection: NSRange(location: 0, length: 6),
                               candidates: texts.enumerated().map { .init(label: "\($0.offset + 1)", text: $0.element) })
        return PanelPreview(theme: theme, state: state)
            .fixedSize()
            .padding(18)
            .frame(maxWidth: .infinity)
            .frame(height: choices.layout == "stacked" ? 300 : 150)
            .clipped()
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardBorder))
            .animation(.snappy, value: choices)
    }
}

private struct SmartStep: View {
    @Binding var choices: OnboardingView.Choices

    var body: some View {
        VStack(spacing: 10) {
            FeatureToggle(isOn: $choices.aiActions, symbol: "sparkles", title: "AI 翻译与润色",
                          detail: "长按 ⌥ 或按 ⌃⌥P，对选中或刚打的文字翻译、润色。默认用 Apple 端侧模型；只有你执行时才处理那一段文字。")
            FeatureToggle(isOn: $choices.stats, symbol: "chart.bar.xaxis", title: "输入统计",
                          detail: "每天打了多少字、在哪些应用、高频词。只记数字，不记句子，只存在本机。")
            FeatureToggle(isOn: $choices.smartApps, symbol: "square.grid.2x2", title: "按应用自动切换中英文",
                          detail: "扫描已安装的应用：终端和代码编辑器进入时默认英文，聊天、浏览器和笔记默认中文。")
            FeatureToggle(isOn: $choices.samplePhrases, symbol: "text.quote", title: "添加示例短语",
                          detail: "打 am 出「艾么输入法」、gw 出官网、yx 出邮箱，下一步就用它们演示；随时可在「自定义短语」删除。")
        }
    }
}

/// One task at a time, each with its own fresh field; a finished task checks itself
/// off and the next one slides in. Holding ⌥ is reported by the input method (an event
/// without any text) since the settings app cannot see it.
private struct PracticeStep: View {
    @Environment(SettingsModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var text = ""
    @State private var done: Set<Int> = []
    @State private var menuOpened = false
    @FocusState private var focused: Bool
    let samples: [(code: String, text: String, title: String)]

    private struct Task {
        let keys: String
        let title: String
        let hint: String
        let check: (String, Bool) -> Bool
    }

    private var tasks: [Task] {
        // Short phrase codes work the same in 全拼 and every 双拼 layout.
        var list: [Task] = []
        for sample in samples {
            list.append(Task(keys: sample.code, title: "输入 \(sample.code)，得到\(sample.title)",
                             hint: "短语排在第一位，按空格上屏：\(sample.text)") { text, _ in text.contains(sample.text) })
        }
        list.append(Task(keys: "⌥", title: "长按 ⌥ 打开快捷菜单",
                         hint: "先打几个拼音，再单独按住 ⌥ 约半秒。菜单里按空格进入 AI，数字进入常用语、符号、高频词。") { _, opened in opened })
        return list
    }

    var body: some View {
        let all = tasks
        let task = all[min(index, all.count - 1)]
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                ForEach(all.indices, id: \.self) { i in
                    Image(systemName: done.contains(i) ? "checkmark.circle.fill" : i == index ? "circle.inset.filled" : "circle")
                        .foregroundStyle(done.contains(i) ? AnyShapeStyle(Theme.success) : i == index ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                }
                Spacer()
                if case .deploying = model.deployState {
                    Label("正在应用你的设置…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text(task.keys).font(.system(.title3, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(Theme.accentText)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).font(.title3.weight(.semibold))
                        Text(task.hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                TextField("在这里打字…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
                    .padding(16)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(done.contains(index) ? Theme.success : Theme.accent.opacity(0.5), lineWidth: done.contains(index) ? 2 : 1))
                if done.contains(index) {
                    Label(index + 1 < all.count ? "完成，下一项…" : "全部完成", systemImage: "checkmark.seal.fill")
                        .font(.callout.weight(.medium)).foregroundStyle(Theme.success)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .id(index)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                               removal: .move(edge: .leading).combined(with: .opacity)))
            HStack {
                Button("上一项") { move(to: index - 1) }.buttonStyle(.borderless).disabled(index == 0)
                Spacer()
                Button(index + 1 < all.count ? "跳过这一项" : "") { move(to: index + 1) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).disabled(index + 1 >= all.count)
            }
            .font(.callout)
        }
        .onAppear { focused = true }
        .onChange(of: text) { _, value in evaluate(value) }
        .onChange(of: menuOpened) { _, opened in if opened { evaluate(text) } }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("app.zool.aime.menu.opened"))) { _ in
            menuOpened = true
        }
    }

    private func evaluate(_ value: String) {
        let all = tasks
        guard all.indices.contains(index), !done.contains(index), all[index].check(value, menuOpened) else { return }
        withAnimation(.snappy) { _ = done.insert(index) }
        let finished = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if index == finished, finished + 1 < all.count { move(to: finished + 1) }
        }
    }

    private func move(to target: Int) {
        guard tasks.indices.contains(target) else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.45, bounce: 0.12)) {
            index = target
            text = ""
        }
        if target == tasks.count - 1 { menuOpened = false } // the hold must happen on this task
        DispatchQueue.main.async { focused = true }
    }
}

private struct DoneStep: View {
    var body: some View {
        let tips: [(String, String, String)] = [
            ("⇧", "切换中英文", "单按 Shift；每个应用会记住自己的状态"),
            ("⌥", "快捷菜单", "打字时长按：常用语、符号、高频词，空格进入 AI"),
            ("⌃⌥P", "AI 处理", "对选中或刚打的文字翻译、润色、简繁转换"),
            ("⌃⇧4", "简繁切换", "临时切换输出简体或繁体"),
        ]
        VStack(spacing: 10) {
            ForEach(tips, id: \.0) { key, title, detail in
                HStack(spacing: 14) {
                    Text(key).font(.system(.body, design: .rounded).weight(.semibold))
                        .frame(minWidth: 56)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.body.weight(.medium))
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

// MARK: - Pieces

private struct EnableStatusCard: View {
    let done: Bool
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: done ? "checkmark.seal.fill" : "keyboard.badge.ellipsis")
                .font(.system(size: 26))
                .foregroundStyle(done ? AnyShapeStyle(Theme.success) : AnyShapeStyle(Theme.accent))
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(done ? Theme.success.opacity(0.5) : Theme.cardBorder))
    }
}

private struct ChoiceCard: View {
    let selected: Bool
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.secondary))
                Text(title).font(.title3.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.cardBorder, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled() // the selection outline is the only highlight
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct FlowChips: View {
    let items: [(id: String, title: String)]
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.id) { item in
                Button { pick(item.id) } label: {
                    Text(item.title).font(.callout.weight(item.id == selected ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(item.id == selected ? AnyShapeStyle(Theme.accent.opacity(0.14)) : AnyShapeStyle(Theme.card),
                                    in: Capsule())
                        .overlay(Capsule().strokeBorder(item.id == selected ? Theme.accent : Theme.cardBorder))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct FeatureToggle: View {
    @Binding var isOn: Bool
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.secondary))
                .frame(width: 34, height: 34)
                .background((isOn ? Theme.accent : Color.primary).opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.snappy, value: isOn)
    }
}

/// The turning ring of colour the candidate panel wears for AI, as a SwiftUI view.
private struct GlowRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let size: CGFloat
    let lineWidth: CGFloat
    let blur: CGFloat
    @State private var angle = 0.0

    static let colors: [Color] = [
        Color(red: 0.10, green: 0.60, blue: 1.00), Color(red: 0.13, green: 0.83, blue: 0.93), Color(red: 0.20, green: 0.83, blue: 0.60),
        Color(red: 0.98, green: 0.75, blue: 0.14), Color(red: 0.20, green: 0.83, blue: 0.60), Color(red: 0.13, green: 0.83, blue: 0.93),
        Color(red: 0.10, green: 0.60, blue: 1.00),
    ]

    var body: some View {
        let ring = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .strokeBorder(AngularGradient(colors: Self.colors, center: .center, angle: .degrees(angle)), lineWidth: lineWidth)
            .frame(width: size, height: size)
        ZStack {
            ring.blur(radius: blur).opacity(0.8)
            ring.opacity(0.9)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { angle = 360 }
        }
    }
}

/// Soft colour washes behind the guide.
private struct AmbientGlow: View {
    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.10, green: 0.60, blue: 1.00).opacity(0.10)).frame(width: 420).blur(radius: 90).offset(x: -220, y: -160)
            Circle().fill(Color(red: 0.20, green: 0.83, blue: 0.60).opacity(0.08)).frame(width: 380).blur(radius: 90).offset(x: 240, y: 180)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Presentation

/// On first launch (or with `--onboarding`) the window shows only the guide, the way
/// Mac apps greet a new user; the settings appear once it is done. 「高级」 can run it again.
private struct OnboardingHost: ViewModifier {
    @AppStorage("onboarding.completed") private var completed = false
    @State private var presented = OnboardingHost.shouldShow(completed: UserDefaults.standard.bool(forKey: "onboarding.completed"))

    func body(content: Content) -> some View {
        ZStack {
            if presented {
                OnboardingView {
                    completed = true
                    withAnimation(.easeInOut(duration: 0.35)) { presented = false }
                }
                .frame(minWidth: 780, minHeight: 620)
                // Full-bleed: no title bar band, only the window controls over the guide.
                .ignoresSafeArea()
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .transition(.opacity)
            } else {
                content.transition(.opacity)
            }
        }
        .onChange(of: completed) { _, done in
            if !done { withAnimation(.easeInOut(duration: 0.35)) { presented = true } }
        }
    }

    static func shouldShow(completed: Bool) -> Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--onboarding") { return true }
        // Screenshot automation opens panes directly; never cover them.
        return !completed && LaunchOptions.pane == nil
    }
}

extension View {
    func onboardingHost() -> some View { modifier(OnboardingHost()) }
}

/// 「重新运行新手引导」 in 高级.
struct RerunOnboardingButton: View {
    @AppStorage("onboarding.completed") private var completed = false

    var body: some View {
        Button { completed = false } label: { Label("新手引导", systemImage: "sparkles.rectangle.stack") }
            .help("重新运行首次启动的引导")
    }
}
