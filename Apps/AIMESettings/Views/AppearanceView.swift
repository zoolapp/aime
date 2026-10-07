import AIMECore
import AIMEPanel
import SwiftUI

struct AppearanceView: View {
    @Environment(SettingsModel.self) private var model
    @Environment(\.colorScheme) private var systemScheme
    @State private var previewDark: Bool?

    private var dark: Bool { previewDark ?? (systemScheme == .dark) }

    var body: some View {
        let theme = model.theme(dark: dark)
        Form {
            Section { PaneHeader(title: "外观", subtitle: "配色、字体与候选窗布局。预览即输入法中的真实渲染，修改后自动生效。", symbol: "paintpalette") }


            Section {
                VStack(spacing: 14) {
                    Picker("预览模式", selection: Binding(get: { dark }, set: { previewDark = $0 })) {
                        Label("浅色", systemImage: "sun.max").tag(false)
                        Label("深色", systemImage: "moon").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    PanelPreview(theme: theme)
                        .padding(30)
                        .frame(maxWidth: .infinity)
                        .background(
                            LinearGradient(colors: dark ? [Color(white: 0.16), Color(white: 0.1)] : [Color(white: 0.93), Color(white: 0.86)],
                                           startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    if theme.minimumTextContrast < 3 {
                        Label("当前配色文字对比度偏低（\(theme.minimumTextContrast, format: .number.precision(.fractionLength(1))):1），可能看不清。",
                              systemImage: "eye.trianglebadge.exclamationmark")
                            .font(.callout).foregroundStyle(Theme.warning)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("配色方案") {
                SchemeGallery(dark: dark)
            }

            if model.previewFrontend.value(at: "style/color_scheme")?.stringValue == SettingsModel.customSchemeID {
                Section("我的配色") {
                    ForEach(model.catalog.settings(in: "appearance").filter { $0.keypath.hasPrefix("preset_color_schemes/aime_custom/") }) {
                        SettingRow(setting: $0)
                    }
                }
            }

            Section("布局") {
                rows(["appearance.candidate_list_layout", "appearance.inline_preedit", "appearance.inline_candidate",
                      "appearance.translucency", "appearance.alpha"])
            }
            Section("候选窗菜单按钮") {
                Toggle(isOn: Binding(get: { model.features.panelMenuButton }, set: { on in model.updateFeatures { $0.panelMenuButton = on } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("在候选窗末尾显示 AIME 菜单按钮")
                        Text("点按钮或按 ⌃⌥M 打开。长按触发键在「快捷键 → 快捷菜单」中设置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("字体") {
                rows(["appearance.font_face", "appearance.font_point", "appearance.label_font_face", "appearance.label_font_point",
                      "appearance.comment_font_face", "appearance.comment_font_point", "appearance.candidate_format"])
            }
            Section("尺寸与间距") {
                rows(["appearance.max_width", "appearance.corner_radius", "appearance.hilited_corner_radius", "appearance.border_width",
                      "appearance.border_height", "appearance.spacing", "appearance.line_spacing", "appearance.base_offset"])
            }
        }
        .formStyle(.cards)
    }

    @ViewBuilder
    private func rows(_ ids: [String]) -> some View {
        ForEach(ids.compactMap(model.setting), id: \.id) { SettingRow(setting: $0) }
    }
}

/// Color schemes grouped by brightness. Thumbnails use one layout and font size so only
/// the colors differ, in tiles of a fixed size (schemes bring their own fonts and
/// layouts, which made the tiles overlap).
private struct SchemeGallery: View {
    @Environment(SettingsModel.self) private var model
    let dark: Bool

    private struct Entry: Identifiable {
        let id: String
        let name: String
        let theme: PanelTheme
    }

    var body: some View {
        let key = dark ? "style/color_scheme_dark" : "style/color_scheme"
        let frontend = model.previewFrontend
        let selected = frontend.value(at: key)?.stringValue ?? frontend.value(at: "style/color_scheme")?.stringValue
        let entries = model.colorSchemes.map { Entry(id: $0.id, name: $0.name, theme: model.theme(dark: dark, scheme: $0.id)) }
        let lightOnes = entries.filter { !$0.theme.hasDarkBackground }
        let darkOnes = entries.filter(\.theme.hasDarkBackground)
        // The group that matches the mode being configured comes first.
        let groups: [(title: String, items: [Entry])] = dark
            ? [("深色配色", darkOnes), ("浅色配色", lightOnes)]
            : [("浅色配色", lightOnes), ("深色配色", darkOnes)]
        VStack(alignment: .leading, spacing: 18) {
            Text(dark ? "选择深色模式下使用的配色" : "选择浅色模式下使用的配色").font(.callout).foregroundStyle(.secondary)
            ForEach(groups.filter { !$0.items.isEmpty }, id: \.title) { group in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text(group.title).font(.subheadline.weight(.semibold))
                        Text("\(group.items.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(group.items) { entry in
                            SchemeTile(name: entry.name, theme: entry.theme, selected: selected == entry.id) {
                                if let setting = model.setting(dark ? "appearance.color_scheme_dark" : "appearance.color_scheme") {
                                    model.set(.string(entry.id), for: setting)
                                }
                            }
                        }
                    }
                }
            }
            Button {
                model.customizeScheme(from: model.theme(dark: dark))
            } label: {
                Label("基于当前配色自定义…", systemImage: "slider.horizontal.3")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SchemeTile: View {
    let name: String
    let theme: PanelTheme
    let selected: Bool
    let action: () -> Void

    /// Same geometry for every scheme: horizontal, 14 pt, modest insets.
    private var thumbnailTheme: PanelTheme {
        var copy = theme
        copy.layout = .linear
        copy.fontPoint = 14
        copy.labelFontPoint = 11
        copy.commentFontPoint = 11
        copy.borderWidth = min(copy.borderWidth, 5)
        copy.borderHeight = min(copy.borderHeight, 4)
        copy.spacing = 7
        copy.translucency = false
        copy.alpha = 1
        return copy
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                PanelPreview(theme: thumbnailTheme, state: .gallerySample)
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                    .background(theme.hasDarkBackground ? Color(white: 0.20) : Color(white: 0.90))
                    .clipped()
                HStack(spacing: 6) {
                    Text(name).font(.callout).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentText) }
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
            }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.cardBorder, lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension PanelState {
    static let gallerySample = PanelState(candidates: [
        .init(label: "1", text: "输入法"), .init(label: "2", text: "输入"), .init(label: "3", text: "AIME"),
    ])
}
