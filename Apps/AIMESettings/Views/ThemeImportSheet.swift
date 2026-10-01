import AIMECore
import AIMEPanel
import SwiftUI

/// Confirms an `aime-ime://theme` link before anything is written: light and dark previews
/// with the user's own layout, legibility, and where the theme will be used.
struct ThemeImportSheet: View {
    @Environment(SettingsModel.self) private var model
    let decoded: ThemePackage.Decoded
    @State private var target: ThemeImportPlan.Target
    @State private var adoptLayout = true

    init(decoded: ThemePackage.Decoded, prefersDark: Bool) {
        self.decoded = decoded
        _target = State(initialValue: prefersDark ? .dark : .light)
    }

    private var package: ThemePackage { decoded.package }

    var body: some View {
        let plan = model.themeImportPlan(package)
        let light = model.theme(for: package, dark: false, adoptLayout: adoptLayout && package.layout != nil)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "paintpalette.fill").font(.title2).foregroundStyle(Theme.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("导入主题「\(package.name)」").font(.title3.weight(.semibold))
                    Text(subtitle(plan)).font(.callout).foregroundStyle(Theme.secondaryText)
                }
            }

            VStack(spacing: 10) {
                preview(light, label: "浅色桌面", background: Color(white: 0.93))
                preview(light, label: "深色桌面", background: Color(white: 0.16))
            }

            VStack(alignment: .leading, spacing: 8) {
                if light.minimumTextContrast < 3 {
                    Label("文字对比度偏低（\(light.minimumTextContrast, format: .number.precision(.fractionLength(1))):1），可能看不清。",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let replaced = plan.replaces {
                    Label("将替换之前导入的「\(replaced)」。", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.red)
                }
                if !decoded.ignoredKeys.isEmpty {
                    Label("已忽略不支持的字段：\(decoded.ignoredKeys.joined(separator: "、"))", systemImage: "info.circle")
                        .foregroundStyle(Theme.secondaryText)
                }
                if package.layout != nil {
                    Toggle("同时采用主题的布局（圆角、边距、间距、字号），与官网预览一致", isOn: $adoptLayout)
                        .toggleStyle(.checkbox)
                    Text(adoptLayout ? "会替换你在「外观」里设置的这些数值；字体、横竖排与「我的配色」不变。"
                         : "只导入颜色，沿用你当前的布局。")
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    Text("这个主题只包含颜色，不会改动你的字体、布局或「我的配色」。")
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .font(.callout)

            Picker("用于", selection: $target) {
                Text("浅色模式").tag(ThemeImportPlan.Target.light)
                Text("深色模式").tag(ThemeImportPlan.Target.dark)
                Text("两者").tag(ThemeImportPlan.Target.both)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            HStack {
                if model.themeImports.count > 1 {
                    Text("还有 \(model.themeImports.count - 1) 个主题等待确认").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button("取消", role: .cancel) { model.cancelThemeImport() }
                    .keyboardShortcut(.cancelAction)
                if !plan.isBuiltIn {
                    Button("仅导入") { model.confirmThemeImport(activate: false, target: target, adoptLayout: adoptLayout && package.layout != nil) }
                }
                Button(plan.isBuiltIn ? "启用" : "导入并启用") { model.confirmThemeImport(activate: true, target: target, adoptLayout: adoptLayout && package.layout != nil) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 680)
    }

    private func subtitle(_ plan: ThemeImportPlan) -> String {
        var parts = [package.author.map { "作者 \($0)" } ?? "未署名"]
        parts.append(plan.isBuiltIn ? "与内置主题同名，将直接切换到内置版本" : "ID \(package.id)")
        return parts.joined(separator: " · ")
    }

    private func preview(_ theme: PanelTheme, label: String, background: Color) -> some View {
        PanelPreview(theme: theme)
            .fixedSize()
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) {
                Text(label).font(.caption2).foregroundStyle(background == Color(white: 0.16) ? Color(white: 0.75) : Color(white: 0.35))
                    .padding(8)
            }
            .clipped()
    }
}

extension View {
    /// Receives `aime-ime://theme` links (and `--import-theme-url` from screenshot automation)
    /// and presents the confirmation sheet for the first queued theme.
    func themeImportHost(_ model: SettingsModel) -> some View {
        modifier(ThemeImportHost(model: model))
    }
}

private struct ThemeImportHost: ViewModifier {
    let model: SettingsModel

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                model.receiveThemeLink(url)
                NSApp.activate()
            }
            .task {
                if let link = LaunchOptions.argument("--import-theme-url"), let url = URL(string: link) {
                    model.receiveThemeLink(url)
                }
            }
            .sheet(item: Binding(get: { model.themeImports.first.map(QueuedTheme.init) }, set: { _ in })) { item in
                let back = item.decoded.package.colors["back_color"].flatMap { ThemeColor(rime: .string($0), format: "argb") }
                ThemeImportSheet(decoded: item.decoded, prefersDark: (back?.luminance ?? 1) < 0.18)
                    .environment(model)
                    .id(item.id)
            }
            .overlay(alignment: .top) {
                if let notice = model.themeNotice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: notice) {
                            try? await Task.sleep(for: .seconds(4))
                            model.dismissThemeNotice()
                        }
                }
            }
            .alert("无法导入主题", isPresented: Binding(get: { model.themeImportError != nil }, set: { if !$0 { model.dismissThemeImportError() } })) {
                Button("好") { model.dismissThemeImportError() }
            } message: {
                Text(model.themeImportError ?? "")
            }
    }
}

private struct QueuedTheme: Identifiable {
    let decoded: ThemePackage.Decoded
    var id: String { decoded.package.payload }
}
