import AIMECore
import AIMEPanel
import AppKit
import SwiftUI

/// Large page title with a one-line explanation, shared by every pane.
struct PaneHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let symbol: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 38, height: 38)
                .foregroundStyle(.white)
                .background(Theme.iconTile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                Text(subtitle).font(.callout).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
        .containerValue(\.isPlain, true)
    }
}

/// A catalog-driven form pane (输入习惯 / 中英切换 / 模糊音 / 快捷键).
struct CatalogPane: View {
    @Environment(SettingsModel.self) private var model
    let pane: Pane

    var subtitle: LocalizedStringKey {
        switch pane {
        case .general: "候选词数量、方案选单与翻译器行为。"
        case .switching: "Caps Lock 与 Shift 在输入中的行为，以及中英文切换方式。"
        case .spelling: "模糊音、简拼与自动纠错。开关会写入当前主方案的拼写运算规则。"
        case .keys: "快捷菜单与方案选单的触发方式，以及选词、翻页和输入开关。"
        default: ""
        }
    }

    var body: some View {
        let settings = model.catalog.settings(in: pane.catalogGroup ?? "")
            .filter { $0.type != .custom && !CatalogPane.shownElsewhere.contains($0.id) }
        Form {
            Section { PaneHeader(title: pane.title, subtitle: subtitle, symbol: pane.symbol) }

            if pane == .spelling, let schema = model.enabledSchemas.first {
                Section {
                    Label("作用于主方案「\(schema)」", systemImage: "info.circle").foregroundStyle(.secondary).font(.callout)
                }
            }
            if pane == .general { ScriptSection() }
            if pane == .keys {
                QuickMenuShortcutsSection()
                Section("方案选单") {
                    ForEach(settings.filter { $0.id == "switcher.hotkeys" }) { SettingRow(setting: $0) }
                }
                Section("选词、翻页与输入开关") {
                    ForEach(settings.filter { $0.id != "switcher.hotkeys" }) { SettingRow(setting: $0) }
                }
            } else {
                Section {
                    ForEach(settings) { setting in SettingRow(setting: setting) }
                }
            }
        }
        .formStyle(.cards)
    }

    /// Catalog settings drawn in a section of their own.
    static let shownElsewhere: Set<String> = ["traditionalize.opencc_config"]
}

/// Trigger behavior belongs with shortcuts; the candidate button's visibility stays
/// in Appearance. Uses the existing features save/notification channel.
private struct QuickMenuShortcutsSection: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        Section {
            LabeledContent {
                Picker("快捷菜单长按键", selection: Binding(
                    get: { model.features.menuHoldKey },
                    set: { key in model.updateFeatures { $0.menuHoldKey = key } }
                )) {
                    Text("⌥ Option").tag(ModifierHold.Key.option)
                    Text("⌃ Control").tag(ModifierHold.Key.control)
                    Text("⌘ Command").tag(ModifierHold.Key.command)
                    Text("关闭").tag(ModifierHold.Key.off)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("快捷菜单长按键")
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("长按触发键")
                    Text("打字时单独按住约 0.35 秒，打开常用语、符号和表情菜单；与其他键组合时不触发。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent("组合键打开", value: "⌃⌥M（固定）")
        } header: {
            Text("快捷菜单")
        } footer: {
            Text("关闭长按后仍可用 ⌃⌥M 打开。方案选单是切换输入方案和开关的菜单，触发键在下方单独设置。")
        }
    }
}

/// 简体 / 繁体: the default output, the Traditional standard, and how to switch or convert.
private struct ScriptSection: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        Section {
            LabeledContent {
                Picker("", selection: Binding(get: { model.features.traditional }, set: { value in model.updateFeatures { $0.traditional = value } })) {
                    Text("简体").tag(false)
                    Text("繁体").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.trailing, 28) // lines up with catalog rows (their reset-button slot)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("默认输出")
                    Text("打字时按 ⌃⇧4 临时切换。已经打出的文字：选中或刚打完后按 ⌃⌥P，选「简繁转换」，在本机转换，不经过 AI。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let setting = model.setting("traditionalize.opencc_config") { SettingRow(setting: setting) }
        } header: {
            Text("简繁体")
        }
    }
}

/// Renders the right control for a catalog setting and writes changes back.
struct SettingRow: View {
    @Environment(SettingsModel.self) private var model
    let setting: SettingCatalog.Setting

    var body: some View {
        let customized = model.isCustomized(setting)
        LabeledContent {
            // Every control ends on the same trailing line: the reset button has a
            // fixed slot whether or not it is shown.
            HStack(spacing: 10) {
                control
                ZStack {
                    if customized {
                        Button {
                            model.reset(setting)
                        } label: {
                            Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.borderless)
                        .help("恢复为导入或默认值")
                    }
                }
                .frame(width: 18)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(setting.title)
                    if customized {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6).help("已自定义")
                    }
                }
                if let description = setting.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var control: some View {
        let current = model.value(setting)
        switch setting.type {
        case .bool: boolControl(current)
        case .int: intControl(current)
        case .double:
            let value = current?.doubleValue ?? setting.default?.doubleValue ?? 0
            if let steps = setting.options, !steps.isEmpty {
                // A few fixed sizes (font sizes): stepped "A" control instead of a free number.
                SizeStepControl(steps: steps.compactMap { step in step.value.doubleValue.map { ($0, step.title) } },
                                range: setting.min.flatMap { min in setting.max.map { min...$0 } }, value: value) {
                    model.set(.double($0), for: setting)
                }
            } else {
                DoubleControl(setting: setting, value: value)
            }
        case .enum: enumControl(current)
        case .font: FontPicker(value: current?.stringValue ?? "") { model.set(.string($0), for: setting) }
        case .color: colorControl(current)
        case .stringList: listControl(current)
        case .hotkey:
            KeyRecorder(value: current?.stringValue ?? "") { model.set(.string($0), for: setting) }
        case .hotkeyList:
            HotkeyListControl(values: (current?.listValue ?? []).compactMap(\.stringValue)) {
                model.set(.list($0.map(ConfigValue.string)), for: setting)
            }
        case .switchList:
            SwitchListControl(
                selected: (current?.listValue ?? []).compactMap(\.stringValue),
                available: model.availableSwitches
            ) { model.set(.list($0.map(ConfigValue.string)), for: setting) }
        case .gramModel:
            let selected = current?.stringValue ?? ""
            Picker("", selection: Binding(
                get: { current?.stringValue ?? "" },
                set: { model.set(.string($0), for: setting) }
            )) {
                Text("关闭").tag("")
                ForEach(model.gramModels, id: \.self) { Text($0).tag($0) }
                if !selected.isEmpty && !model.gramModels.contains(selected) {
                    Text("\(selected)（文件缺失）").tag(selected)
                }
            }
            .labelsHidden()
            .fixedSize()
        case .string: textControl(current)
        case .custom: EmptyView()
        }
    }

    private func boolControl(_ current: ConfigValue?) -> some View {
        let binding = Binding<Bool>(get: { current?.boolValue ?? false }, set: { model.set(.bool($0), for: setting) })
        return Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch)
    }

    private func intControl(_ current: ConfigValue?) -> some View {
        let value: Int = current?.intValue ?? setting.default?.intValue ?? 0
        let range: ClosedRange<Int> = Int(setting.min ?? 0)...Int(setting.max ?? 99)
        let binding = Binding<Int>(get: { value }, set: { model.set(.int($0), for: setting) })
        return HStack(spacing: 6) {
            Text("\(value)").monospacedDigit().font(.body.weight(.medium)).frame(minWidth: 24, alignment: .trailing)
            Stepper("", value: binding, in: range).labelsHidden()
        }
    }

    private func enumControl(_ current: ConfigValue?) -> some View {
        let options: [SettingCatalog.Option] = setting.options ?? []
        let fallback: ConfigValue = setting.default ?? options.first?.value ?? .null
        let binding = Binding<ConfigValue>(get: { current ?? fallback }, set: { model.set($0, for: setting) })
        // Segments only for a few short labels; long ones would be clipped at narrow widths.
        let segmented = options.count <= 3 && options.map(\.title.count).reduce(0, +) <= 12
        return Picker("", selection: binding) {
            ForEach(options) { option in Text(option.title).tag(option.value) }
        }
        .labelsHidden()
        .adaptivePickerStyle(segmented: segmented)
        .fixedSize()
    }

    private func colorControl(_ current: ConfigValue?) -> some View {
        let color: ThemeColor = ThemeColor(rime: current, format: "argb") ?? .clear
        let binding = Binding<Color>(
            get: { Color(themeColor: color) },
            set: { model.set(.string(ThemeColor(color: $0).argbString), for: setting) }
        )
        return ColorPicker("", selection: binding, supportsOpacity: true).labelsHidden()
    }

    private func listControl(_ current: ConfigValue?) -> some View {
        let text: String = (current?.listValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
        return CommitTextField(value: text, placeholder: "用逗号分隔") { text in
            let items: [String] = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            model.set(.list(items.map(ConfigValue.string)), for: setting)
        }
    }

    private func textControl(_ current: ConfigValue?) -> some View {
        let placeholder = setting.type == .hotkey ? "如 Control+grave" : ""
        return CommitTextField(value: current?.stringValue ?? "", placeholder: placeholder) { model.set(.string($0), for: setting) }
    }
}

extension View {
    /// Segmented for a few options, menu otherwise.
    @ViewBuilder
    func adaptivePickerStyle(segmented: Bool) -> some View {
        if segmented { pickerStyle(.segmented) } else { pickerStyle(.menu) }
    }
}

/// Slider for bounded doubles, stepper-backed text field otherwise.
struct DoubleControl: View {
    @Environment(SettingsModel.self) private var model
    let setting: SettingCatalog.Setting
    let value: Double
    @State private var draft: Double?

    var body: some View {
        if let min = setting.min, let max = setting.max {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { draft ?? value }, set: { draft = $0 }), in: min...max) { editing in
                    if !editing, let draft {
                        model.set(.double((draft * 100).rounded() / 100), for: setting)
                        self.draft = nil
                    }
                }
                .frame(width: 160)
                Text((draft ?? value).formatted(.number.precision(.fractionLength(0...2))))
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            }
        } else {
            TextField("", value: Binding(get: { value }, set: { model.set(.double($0), for: setting) }), format: .number)
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Five (or so) preset sizes shown as letters of growing size, with a sliding selection —
/// like the text-size control of a reader app — plus a ±1 pt stepper for a custom size within
/// `range` (#7). Whole points only.
struct SizeStepControl: View {
    let steps: [(value: Double, title: String)]
    /// Bounds for the custom stepper; without them only the presets are offered.
    var range: ClosedRange<Double>? = nil
    let value: Double
    let commit: (Double) -> Void
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The preset matching the value; nil for a custom size.
    private var selectedIndex: Int? {
        steps.firstIndex { $0.value == value.rounded() }
    }

    var body: some View {
        let selected = selectedIndex ?? -1
        HStack(spacing: 10) {
            let points = "\(Int(value.rounded())) pt"
            // Narrow windows drop the preset name rather than clip the label.
            ViewThatFits(in: .horizontal) {
                Text(selectedIndex.map { "\(steps[$0].title) · \(points)" } ?? (range == nil ? points : "自定义 · \(points)"))
                Text(points)
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .lineLimit(1)
            .contentTransition(.numericText())
            HStack(spacing: 0) {
                ForEach(steps.indices, id: \.self) { index in
                    Button {
                        commit(steps[index].value)
                    } label: {
                        Text("A")
                            .font(.system(size: 10.5 + CGFloat(index) * 2.4, weight: index == selected ? .semibold : .regular))
                            .foregroundStyle(index == selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .frame(width: 34, height: 28)
                            .background {
                                if index == selected {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Theme.card)
                                        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                                        .matchedGeometryEffect(id: "selection", in: selection)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(steps[index].title) · \(Int(steps[index].value)) pt")
                    .accessibilityLabel("\(steps[index].title)，\(Int(steps[index].value)) 磅")
                    .accessibilityAddTraits(index == selected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Theme.divider, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: selected)
            if let range {
                Stepper("", value: Binding(
                    get: { min(max(value.rounded(), range.lowerBound), range.upperBound) },
                    set: { commit(min(max($0, range.lowerBound), range.upperBound)) }
                ), in: range, step: 1)
                .labelsHidden()
                .help("自定义字号（\(Int(range.lowerBound))–\(Int(range.upperBound)) pt）")
                .accessibilityLabel("自定义字号")
                .accessibilityValue("\(Int(value.rounded())) 磅")
            }
        }
    }
}

/// Text field that writes on submit / focus loss instead of per keystroke.
struct CommitTextField: View {
    let value: String
    var placeholder: String = ""
    /// Widest the field may get (`.infinity` for long values such as prompts).
    var maxWidth: CGFloat = 260
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        // Title-less field with a prompt: in a macOS Form the title would render as a
        // trailing label next to the control.
        TextField("", text: $text, prompt: placeholder.isEmpty ? nil : Text(placeholder))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 180, maxWidth: maxWidth)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .onSubmit { if text != value { commit(text) } }
            .onChange(of: focused) { _, isFocused in if !isFocused, text != value { commit(text) } }
    }
}

/// Font family picker with a curated list of CJK-capable faces plus free text.
struct FontField: View {
    let value: String
    let commit: (String) -> Void

    static let suggestions: [String] = {
        let preferred = ["PingFang SC", "Hiragino Sans GB", "Songti SC", "Kaiti SC", "LXGW WenKai", "Source Han Sans SC",
                         "Noto Sans CJK SC", "Sarasa Gothic SC", "SF Pro", "SF Pro Rounded", "Helvetica Neue", "Menlo"]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return preferred.filter { installed.contains($0) || $0.hasPrefix("SF Pro") }
    }()

    var body: some View {
        HStack(spacing: 6) {
            CommitTextField(value: value, placeholder: "字体名称", commit: commit)
            Menu {
                ForEach(Self.suggestions, id: \.self) { name in
                    Button(name) { commit(name) }
                }
            } label: {
                Image(systemName: "textformat")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

extension Color {
    init(themeColor: ThemeColor) {
        self.init(.sRGB, red: themeColor.red, green: themeColor.green, blue: themeColor.blue, opacity: themeColor.alpha)
    }
}

extension ThemeColor {
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent, alpha: ns.alphaComponent)
    }
}

/// Hosts the real AppKit candidate view so the preview matches the input method exactly.
struct PanelPreview: NSViewRepresentable {
    let theme: PanelTheme
    var state: PanelState = .sample

    func makeNSView(context: Context) -> CandidateView {
        let view = CandidateView()
        view.forcePreedit = true
        return view
    }

    func updateNSView(_ view: CandidateView, context: Context) {
        view.theme = theme
        view.state = state
        view.forcePreedit = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CandidateView, context: Context) -> CGSize? {
        nsView.fittingContentSize
    }
}
