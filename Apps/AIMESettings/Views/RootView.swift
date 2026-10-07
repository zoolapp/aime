import SwiftUI

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case overview, schemas, general, switching, spelling, keys, appearance, apps, dictionaries, phrases, snippets, sync, stats, ai, advanced, about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "概览"
        case .schemas: "输入方案"
        case .general: "输入习惯"
        case .switching: "中英切换"
        case .spelling: "模糊音与拼写"
        case .keys: "快捷键"
        case .appearance: "外观"
        case .apps: "应用"
        case .dictionaries: "词库"
        case .phrases: "自定义短语"
        case .snippets: "常用语"
        case .sync: "同步与备份"
        case .stats: "输入统计"
        case .ai: "AI 助手"
        case .advanced: "高级"
        case .about: "关于"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "sparkles.rectangle.stack"
        case .schemas: "character.book.closed"
        case .general: "keyboard"
        case .switching: "globe"
        case .spelling: "ear.badge.waveform"
        case .keys: "command"
        case .appearance: "paintpalette"
        case .apps: "square.grid.2x2"
        case .dictionaries: "books.vertical"
        case .phrases: "text.quote"
        case .snippets: "list.bullet.rectangle"
        case .sync: "arrow.triangle.2.circlepath"
        case .stats: "chart.bar.xaxis"
        case .ai: "wand.and.sparkles"
        case .advanced: "wrench.and.screwdriver"
        case .about: "info.circle"
        }
    }

    /// Catalog group rendered generically by this pane, if any.
    var catalogGroup: String? {
        switch self {
        case .general: "general"
        case .switching: "switching"
        case .spelling: "spelling"
        case .keys: "keys"
        default: nil
        }
    }

    @MainActor static let sections: [(LocalizedStringKey, [Pane])] = [
        ("", [.overview]),
        ("智能", [.ai, .stats]),
        ("输入", [.schemas, .general, .switching, .spelling, .keys]),
        ("个性化", [.appearance, .apps]),
        ("词库", [.dictionaries, .phrases, .snippets, .sync]),
        ("系统", [.advanced, .about]),
    ]
}

struct RootView: View {
    @Environment(SettingsModel.self) private var model
    @Binding var selection: Pane?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                // Brand mark instead of a bare system sidebar.
                HStack(spacing: 10) {
                    Image("BrandSquare")
                        .resizable().frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("艾么输入法").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("AIME · 设置").font(.caption2).foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.vertical, 6)
                .listRowSeparator(.hidden)
                .selectionDisabled()
                ForEach(Pane.sections, id: \.1) { title, panes in
                    Section(title) {
                        ForEach(panes) { pane in
                            Label {
                                Text(pane.title)
                            } icon: {
                                Image(systemName: pane.symbol).foregroundStyle(selection == pane ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                            }
                            .tag(pane)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail(for: selection ?? .overview)
                .background(Theme.canvas)
                .overlay(alignment: .top) { DeployProgressBar() }
                .toolbar {
                    if selection != .about {
                        // Status sits outside the button's glass capsule: text on a tinted
                        // (prominent) capsule is unreadable in both light and dark mode.
                        ToolbarItem(placement: .primaryAction) { DeployStatus() }
                            .sharedBackgroundVisibility(.hidden)
                        ToolbarItem(placement: .primaryAction) { DeployButton() }
                    }
                }
        }
        .tint(Theme.accent)
        .onboardingHost(bypassed: selection == .about)
        .themeImportHost(model)
        .overlay(alignment: .bottom) { ErrorBanner() }
        // The input method's quick menu opens a specific pane in a running Settings app.
        .onReceive(DistributedNotificationCenter.default().publisher(for: .init("app.zool.aime.settings.showPane"))) { note in
            if let raw = note.userInfo?["pane"] as? String, let pane = Pane(rawValue: raw) {
                selection = pane
                NSApp.activate()
            }
        }
    }

    @ViewBuilder
    private func detail(for pane: Pane) -> some View {
        switch pane {
        case .overview: OverviewView(selection: $selection)
        case .schemas: SchemasView()
        case .appearance: AppearanceView()
        case .apps: AppOptionsView()
        case .dictionaries: DictionariesView()
        case .phrases: PhrasesView()
        case .snippets: SnippetsView()
        case .sync: SyncView()
        case .stats: UsageStatsView()
        case .ai: AIAssistantView()
        case .advanced: AdvancedView()
        case .about: AboutView()
        default: CatalogPane(pane: pane)
        }
    }
}

/// Changes apply automatically; the toolbar only reports what is happening.
struct DeployStatus: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            switch model.deployState {
            case .deploying:
                ProgressView().controlSize(.small)
                Text(model.deployStage.isEmpty ? "正在应用…" : model.deployStage).foregroundStyle(.secondary)
            case let .failed(message):
                Label("应用失败", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .help(message)
            case .succeeded where !model.hasPendingChanges:
                Label("已生效", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                    .labelStyle(.titleAndIcon)
                    .transition(.opacity)
            default:
                if model.hasPendingChanges {
                    Text("即将应用…").foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .fixedSize()
        .padding(.horizontal, 12) // off the window edge
        .animation(.easeOut(duration: 0.2), value: model.deployState)
    }
}

/// Shown only when an automatic deploy failed; ⇧⌘R still forces a full redeploy.
struct DeployButton: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        if case .failed = model.deployState {
            Button {
                Task { await model.deploy() }
            } label: {
                Label("重试", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
            }
            .help("完整重新部署（⇧⌘R）")
        }
    }
}

/// Thin progress line under the toolbar while settings are being applied.
struct DeployProgressBar: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        if let progress = model.deployProgress {
            GeometryReader { proxy in
                Capsule()
                    .fill(Theme.accent.gradient)
                    .frame(width: max(8, proxy.size.width * progress), height: 3)
                    .animation(.easeOut(duration: 0.25), value: progress)
            }
            .frame(height: 3)
            .opacity(progress >= 1 ? 0 : 1)
            .animation(.easeOut(duration: 0.35).delay(0.1), value: progress >= 1)
            .allowsHitTesting(false)
            .accessibilityLabel("正在应用设置")
            .accessibilityValue(Text("\(Int(progress * 100))%"))
        }
    }
}

struct ErrorBanner: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        if let error = model.lastError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                Text(error).lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("关闭") { model.dismissError() }.buttonStyle(.borderless)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.red.opacity(0.25)))
            .padding(16)
            .frame(maxWidth: 640)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Launch arguments used by screenshot automation (scripts/ui-shots.sh):
/// `--pane <id>` opens a pane, `--appearance light|dark` forces the appearance,
/// `--import-theme-url <aime-ime://theme…>` opens the theme import sheet.
enum LaunchOptions {
    static func argument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static var pane: Pane? { argument("--pane").flatMap(Pane.init(rawValue:)) }
}

extension View {
    /// Prominent when there is something to deploy; a plain bordered button otherwise
    /// (a gray tint reads as "disabled").
    @ViewBuilder
    func adaptiveProminence(_ prominent: Bool) -> some View {
        if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
}
