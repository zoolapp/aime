import AIMECore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Apps

struct AppOptionsView: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        Form {
            Section { PaneHeader(title: "应用", subtitle: "为编程类等应用设置默认英文（首次进入为英文，之后记住你在该应用里的选择，不影响其他应用）、关闭内联预编辑或启用 Vim 模式。", symbol: "square.grid.2x2") }

            Section { SmartSetupCard() }

            Section(model.appOptions.isEmpty ? "" : "已配置的应用") {
                ForEach(model.appOptions) { option in
                    AppOptionRow(option: option)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Button {
                    chooseApp()
                } label: {
                    Label("手动添加应用…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.cards)
        .animation(.snappy(duration: 0.3), value: model.appOptions)
        // `--smart-setup` (UI acceptance): run the scan right away.
        .task { if ProcessInfo.processInfo.arguments.contains("--smart-setup") { await model.scanInstalledApps() } }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "添加"
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        model.setAppOption(.init(bundleID: bundleID, initialMode: .english))
    }
}

/// 智能配置: scan installed apps → review the recommended options → apply.
private struct SmartSetupCard: View {
    @Environment(SettingsModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.appScanPhase {
            case .idle:
                header(title: "智能配置", detail: "扫描已安装的应用，按推荐方案配好：终端、代码编辑器和启动器默认英文，Vim 类编辑器开启 Vim 模式。确认后才会写入，不会改动已有设置。") {
                    Button("开始扫描") { Task { await model.scanInstalledApps() } }.buttonStyle(.borderedProminent)
                }
            case let .scanning(fraction, name, path):
                header(title: "正在扫描已安装的应用…", detail: name.isEmpty ? "准备中" : name) { EmptyView() }
                HStack(spacing: 12) {
                    Group {
                        if let path { Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable() }
                        else { Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary) }
                    }
                    .frame(width: 28, height: 28)
                    .id(path)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .scale(scale: 0.7).combined(with: .opacity), removal: .opacity))
                    ProgressView(value: fraction).progressViewStyle(.linear).tint(Theme.accent)
                    Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
                .animation(.easeOut(duration: 0.12), value: path)
                .animation(.linear(duration: 0.08), value: fraction)
            case .review:
                review
            case let .applied(count):
                header(title: count == 0 ? "没有需要新增的配置" : "已配置 \(count) 个应用",
                       detail: count == 0 ? "" : "已自动应用到输入法，可在下方逐个调整。", symbol: "checkmark.circle.fill", tint: Theme.success) {
                    Button("重新扫描") { Task { await model.scanInstalledApps() } }
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: phaseKey)
    }

    /// Animates phase changes, not every progress tick.
    private var phaseKey: Int {
        switch model.appScanPhase {
        case .idle: 0
        case .scanning: 1
        case .review: 2
        case .applied: 3
        }
    }

    private func header<Trailing: View>(title: String, detail: String, symbol: String = "wand.and.stars", tint: Color = Theme.accent,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .transition(.opacity)
    }

    @ViewBuilder private var review: some View {
        let suggestions = model.appSuggestions
        let selected = suggestions.filter(\.selected).count
        if suggestions.isEmpty {
            header(title: "没有新的推荐", detail: "已安装的应用都已按推荐配置，或不需要特殊处理。", symbol: "checkmark.circle.fill", tint: Theme.success) {
                Button("完成") { model.dismissAppScan() }
            }
        } else {
            let confident = suggestions.filter { $0.rule.selectedByDefault != false }.count
            let optional = suggestions.count - confident
            header(title: "找到 \(confident) 个推荐配置" + (optional > 0 ? "，另有 \(optional) 个可选" : ""),
                   detail: "已按推荐预先选好中文或英文，可以逐个修改；只应用勾选的项。") {
                Button("取消") { model.dismissAppScan() }
                Button("应用 \(selected) 项") { model.applyAppSuggestions() }.buttonStyle(.borderedProminent).disabled(selected == 0)
            }
            let rules = suggestions.reduce(into: [AppRecommendations.Rule]()) { list, item in
                if !list.contains(where: { $0.id == item.rule.id }) { list.append(item.rule) }
            }
            ForEach(rules) { rule in
                let items = suggestions.filter { $0.rule.id == rule.id }
                Group {
                    if rule.selectedByDefault == false {
                        // Broad, opt-in matches stay folded so the confident ones lead.
                        DisclosureGroup {
                            SuggestionList(items: items).padding(.top, 6)
                        } label: {
                            HStack(spacing: 6) {
                                Text("\(rule.title)（\(items.count) 个，可选）").font(.caption.weight(.semibold))
                                Text(rule.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(rule.title).font(.caption.weight(.semibold))
                                Text(rule.reason).font(.caption).foregroundStyle(.secondary)
                            }
                            SuggestionList(items: items)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// One scanned app: tick, icon, name, and the mode it will start in — prefilled with the
/// recommendation and editable before applying.
struct SuggestionRow: View {
    @Environment(SettingsModel.self) private var model
    let suggestion: AppRecommendations.Suggestion

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { suggestion.selected }, set: { _ in model.toggleAppSuggestion(suggestion.id) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("应用到 \(suggestion.app.name)")
            Group {
                if let url = suggestion.app.url { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable() }
                else { Image(systemName: "magnifyingglass.circle.fill").resizable().foregroundStyle(.secondary) }
            }
            .frame(width: 24, height: 24)
            Text(suggestion.app.name).lineLimit(1)
            if !extras.isEmpty { Text(extras).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            Picker("", selection: Binding(get: { suggestion.initialMode }, set: { model.setAppSuggestionMode(suggestion.id, $0) })) {
                Text("中文").tag(SettingsStore.AppOption.InitialMode.chinese)
                Text("英文").tag(SettingsStore.AppOption.InitialMode.english)
                Text("跟随全局").tag(SettingsStore.AppOption.InitialMode.shared)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("\(suggestion.app.name) 进入时的输入状态")
        }
        .labeledContentStyle(.automatic)
        .padding(.vertical, 5)
        .opacity(suggestion.selected ? 1 : 0.62)
    }

    private var extras: String {
        var parts: [String] = []
        if suggestion.option.vimMode { parts.append("Vim 模式") }
        if suggestion.option.noInline { parts.append("不内联") }
        return parts.joined(separator: " · ")
    }
}

/// Rows of one rule as a list with hairlines between them.
private struct SuggestionList: View {
    let items: [AppRecommendations.Suggestion]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("应用").padding(.leading, 62)
                Spacer()
                Text("进入时默认")
            }
            .font(.caption2).foregroundStyle(.tertiary)
            .padding(.bottom, 2)
            ForEach(items) { item in
                Divider().opacity(0.5)
                SuggestionRow(suggestion: item)
            }
        }
    }
}

private struct AppOptionRow: View {
    @Environment(SettingsModel.self) private var model
    let option: SettingsStore.AppOption

    var body: some View {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: option.bundleID)
        HStack(spacing: 12) {
            Image(nsImage: appURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!)
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(appURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? option.bundleID)
                Text(option.bundleID).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Compact checkboxes keep their own layout (not the card's label/content rows).
            Group {
                Picker("", selection: Binding(get: { option.initialMode }, set: { value in
                    var updated = option
                    updated.initialMode = value
                    model.setAppOption(updated)
                })) {
                    Text("默认英文").tag(SettingsStore.AppOption.InitialMode.english)
                    Text("默认中文").tag(SettingsStore.AppOption.InitialMode.chinese)
                    Text("跟随全局").tag(SettingsStore.AppOption.InitialMode.shared)
                }
                .labelsHidden()
                .fixedSize()
                Toggle("不内联", isOn: binding(\.noInline))
                Toggle("Vim", isOn: binding(\.vimMode))
            }
            .toggleStyle(.checkbox)
            .labeledContentStyle(.automatic)
            .fixedSize()
            Button(role: .destructive) { model.removeAppOption(option.bundleID) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<SettingsStore.AppOption, Bool>) -> Binding<Bool> {
        Binding(get: { option[keyPath: keyPath] }, set: { value in
            var updated = option
            updated[keyPath: keyPath] = value
            model.setAppOption(updated)
        })
    }
}

// MARK: - Dictionaries

struct DictionariesView: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        Form {
            Section { PaneHeader(title: "词库", subtitle: "内置雾凇拼音；AI、互联网等专题词库按需订阅；其他输入方案一键安装。", symbol: "books.vertical") }

            Section("内置") {
                LabeledContent {
                    Text(model.baseDictionaryVersion ?? "随 AIME 安装").font(.caption.monospaced()).foregroundStyle(.secondary)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("雾凇拼音 · 基础词库").font(.body.weight(.medium))
                        Text("常用字词、全拼与双拼方案 · GPL-3.0").font(.caption).foregroundStyle(.secondary)
                        if let metadata = model.baseDictionaryMetadata {
                            Text("\(metadata.rawRows.formatted()) 条原始记录（未去重）")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            LanguageModelsSection()
            SubscriptionsSection()
            RecommendedFeedsSection()
            SchemeCatalogSection()
        }
        .formStyle(.cards)
        .task { await model.loadVocabularyCatalog() }
        .scrollTargetForScreenshots()
    }
}

private struct LanguageModelsSection: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        Section {
            ForEach(model.registry.packages.filter { $0.kind == .model }) { package in
                AddonRow(package: package)
            }
        } header: {
            Text("整句语言模型 · 可选")
        } footer: {
            Text("下载后在「输入习惯 → 整句语言模型」中选用。整句选词在本机完成；默认关闭。")
        }
    }
}

/// The official catalog from aime.zool.app: every feed with its size, version and date,
/// one click to subscribe. Added feeds are managed once in SubscriptionsSection.
private struct RecommendedFeedsSection: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        let feeds = model.vocabularyCatalog?.availableFeeds(subscriptions: model.subscriptions) ?? []
        Section {
            if feeds.isEmpty {
                Text(model.vocabularyCatalog?.feeds.isEmpty == false
                     ? "目录中的词库均已添加，可在上方管理更新。"
                     : "暂无可添加词库。请刷新目录，或添加自定义链接。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(feeds) { feed in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: feed.category == "ai" ? "sparkles" : "globe.asia.australia")
                        .foregroundStyle(Theme.accentText).font(.title3).frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(feed.name).font(.body.weight(.medium))
                            if let entries = feed.entries { Text("\(entries) 条补充词").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                        Text(feed.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            if let updated = feed.updated ?? feed.version { Label("更新于 \(updated)", systemImage: "clock") }
                            if let size = feed.size { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
                            if feed.sha256 != nil { Label("SHA-256 校验", systemImage: "checkmark.shield") }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("添加") { Task { await model.addSubscription(url: feed.url.absoluteString, name: feed.name, feed: feed) } }
                        .disabled(!model.canAddSubscription)
                }
                .padding(.vertical, 4)
            }
        } header: {
            HStack {
                Text("可添加词库")
                if let updated = model.vocabularyCatalog?.updated {
                    Text("目录 \(updated)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.loadVocabularyCatalog(force: true) } } label: {
                    Label("刷新目录", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless).controlSize(.small).disabled(model.catalogRefreshing || model.subscriptionActivity != nil)
                if let home = model.vocabularyCatalog?.homepage {
                    Link(destination: home) { Label("官网", systemImage: "arrow.up.right.square") }.font(.caption)
                }
            }
        } footer: {
            Text(model.catalogError ?? "这些是基础词库之外的补充词，可随词表版本扩充。目录登记版本与 SHA-256，下载校验通过才会使用；已订阅词库按设定频率跟进新版本。")
                .font(.caption).foregroundStyle(model.catalogError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning))
        }
    }
}

/// Online vocabularies (e.g. a raw GitHub file), checked at each feed's chosen interval.
private struct SubscriptionsSection: View {
    @Environment(SettingsModel.self) private var model
    @State private var adding = false
    @State private var url = ""

    var body: some View {
        Section {
            ForEach(model.subscriptions) { item in SubscriptionRow(item: item) }
            if adding {
                HStack {
                    TextField("词库地址", text: $url, prompt: Text("https://github.com/…/words.txt"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("粘贴") { url = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? url }
                    Button("取消") { adding = false; url = "" }
                    Button("订阅", action: add).buttonStyle(.borderedProminent).disabled(url.isEmpty || !model.canAddSubscription)
                }
                .controlSize(.small)
                Text("支持 RIME dict.yaml、「词条⇥编码⇥权重」表格或每行一个词；拼音自动生成，全拼与小鹤双拼均可打出。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let activity = model.subscriptionActivity {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(activity).font(.caption).foregroundStyle(.secondary) }
            }
            if let notice = model.subscriptionNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("已添加词库")
                Spacer()
                if !model.subscriptions.isEmpty {
                    Button { Task { await model.refreshSubscriptions() } } label: { Label("立即检查", systemImage: "arrow.clockwise") }
                        .buttonStyle(.borderless).controlSize(.small)
                        .disabled(model.subscriptionActivity != nil || model.catalogRefreshing)
                }
                if !adding {
                    Button {
                        // Prefill from the clipboard when it already holds a link.
                        let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        url = SubscriptionManager.normalize(clip) != nil ? clip : ""
                        adding = true
                    } label: { Label("添加", systemImage: "plus") }
                        .buttonStyle(.borderless).controlSize(.small)
                        .disabled(!model.canAddSubscription)
                }
            }
        } footer: {
            if model.subscriptions.isEmpty && !adding {
                Text("可以添加下方目录中的词库，或粘贴兼容 RIME 的单表链接。每个词库可设为每天、每周自动更新或仅手动；新词在你停止打字后自动生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.subscriptions.count >= SubscriptionManager.maxSubscriptions {
                Text("最多添加 \(SubscriptionManager.maxSubscriptions) 个在线词库；移除旧订阅后可以继续添加。已有订阅仍会保留，每次最多检查 \(SubscriptionManager.maxBatchSize) 个。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func add() {
        let value = url
        Task {
            if await model.addSubscription(url: value, name: nil) {
                adding = false
                url = ""
            }
        }
    }
}

private struct SubscriptionRow: View {
    @Environment(SettingsModel.self) private var model
    let item: VocabularySubscription

    var body: some View {
        let feed = model.vocabularyCatalog?.feeds.first { $0.matches(item) }
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(Theme.accentText).font(.title3).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body.weight(.medium))
                    Text("\(item.entryCount) 条补充词").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if feed != nil { Text("目录词库").font(.caption).foregroundStyle(.secondary) }
                    if item.newEntries > 0 {
                        Text("+\(item.newEntries) 新词").font(.caption.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.success.opacity(0.15), in: Capsule()).foregroundStyle(Theme.success)
                    }
                }
                if let feed {
                    Text(feed.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(item.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 10) {
                    if let updated = item.remoteUpdated {
                        Label("词库更新于 \(updated.formatted(.relative(presentation: .named)))", systemImage: "clock")
                            .help(updated.formatted(date: .complete, time: .standard))
                    }
                    if let checked = item.lastChecked {
                        Text("检查于 \(checked.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                if !item.recentWords.isEmpty {
                    Text("最近新增：" + item.recentWords.prefix(8).joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let error = item.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warning)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Picker("", selection: Binding(get: { item.updateInterval }, set: { model.setSubscriptionInterval(item.id, $0) })) {
                    ForEach(VocabularySubscription.UpdateInterval.allCases, id: \.self) { Text($0 == .manual ? "仅手动更新" : "\($0.title)自动更新").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .help("自动检查新版本的频率")
                Button("移除", role: .destructive) { Task { await model.removeSubscription(item.id) } }
                    .controlSize(.small)
                    .disabled(model.subscriptionActivity != nil)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 输入方案: one card per scheme (editions of one scheme share a card), saying who it
/// suits, whether it is the one in use, and what installing it replaces. Dictionary
/// add-ons sit on their scheme's card; rarely needed packages fold away under 高级.
private struct SchemeCatalogSection: View {
    @Environment(SettingsModel.self) private var model
    @State private var editions: [String: String] = [:]
    @State private var confirm: DictionaryPackage?

    private struct Card: Identifiable {
        let id: String
        let packages: [DictionaryPackage]
    }

    var body: some View {
        let packages = model.registry.packages
        let schemes = packages.filter { $0.kind == .schema }
        var cards: [Card] = []
        for package in schemes {
            let key = package.family ?? package.id
            if let index = cards.firstIndex(where: { $0.id == key }) {
                cards[index] = Card(id: key, packages: cards[index].packages + [package])
            } else {
                cards.append(Card(id: key, packages: [package]))
            }
        }
        let advanced = packages.filter { $0.kind == .dictionary && $0.addonFor == nil }
        return Group {
            Section {
                ForEach(cards) { card in SchemeCard(card: card.packages, edition: binding(for: card), confirm: $confirm) }
            } header: {
                Text("输入方案").id("schemes")
            } footer: {
                Text("日常用一个方案就够了。装好后点「设为主方案」，或在「输入方案」里调整顺序。安装或卸载后自动部署；被替换的同名文件会备份到 aime/backup/。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !advanced.isEmpty {
                Section {
                    DisclosureGroup("其他词库（一般用不到）") {
                        ForEach(advanced) { package in AddonRow(package: package).padding(.top, 6) }
                    }
                }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            if let package = confirm {
                Button("替换并安装") { Task { await model.installReplacing(package) } }
                Button("取消", role: .cancel) {}
            }
        } message: {
            Text("同名文件会先备份到 aime/backup/，之后可以重新安装原来的方案。")
        }
    }

    private var confirmTitle: String {
        guard let package = confirm else { return "" }
        let names = (package.conflicts ?? []).compactMap { id in model.registry.package(id).flatMap { model.installed(id) != nil ? $0.title : nil } }
        return "安装「\(package.title)」会替换已安装的「\(names.joined(separator: "、"))」"
    }

    private func binding(for card: Card) -> Binding<String> {
        Binding(get: {
            editions[card.id] ?? card.packages.first { model.installed($0.id) != nil }?.id ?? card.packages[0].id
        }, set: { editions[card.id] = $0 })
    }
}

private struct SchemeCard: View {
    @Environment(SettingsModel.self) private var model
    let card: [DictionaryPackage]
    @Binding var edition: String
    @Binding var confirm: DictionaryPackage?

    var body: some View {
        let package = card.first { $0.id == edition } ?? card[0]
        let installed = model.installed(package.id)
        let primary = model.enabledSchemas.first
        let inUse = installed != nil && package.schemas.contains { $0 == primary }
        let activity = model.packageActivity[package.id]
        let addon = model.registry.packages.first { $0.addonFor == package.id }
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "character.book.closed.fill")
                .font(.title3).foregroundStyle(inUse ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.secondary))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(card.count > 1 ? package.title.components(separatedBy: " · ").first ?? package.title : package.title)
                        .font(.body.weight(.semibold))
                    if inUse {
                        Text("正在使用").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule()).foregroundStyle(Theme.onAccent)
                    } else if installed != nil {
                        Text("已安装").font(.caption2.weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.success.opacity(0.15), in: Capsule()).foregroundStyle(Theme.success)
                    }
                    Text(installed?.version ?? package.version).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if card.count > 1 {
                    Picker("", selection: $edition) {
                        ForEach(card) { item in Text(item.edition ?? item.title).tag(item.id) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Text(package.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let audience = package.audience {
                    Label(audience, systemImage: "person.crop.circle").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    if let size = package.size { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
                    Text(package.license)
                    Link(destination: URL(string: package.homepage)!) { Label("主页", systemImage: "arrow.up.right.square") }
                    if let others = conflictNames(package), !others.isEmpty {
                        Label("与\(others)互相替换", systemImage: "arrow.left.arrow.right").foregroundStyle(Theme.warning)
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                if let activity { Text(activity).font(.caption).foregroundStyle(Theme.accentText) }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                if activity != nil {
                    ProgressView().controlSize(.small)
                } else if installed == nil {
                    Button("安装") { install(package) }.buttonStyle(.borderedProminent)
                } else {
                    if !inUse, let schema = package.schemas.first {
                        Button("设为主方案") { model.makePrimary(schema) }.buttonStyle(.borderedProminent)
                    }
                    Menu {
                        if installed?.version != package.version { Button("更新到 \(package.version)") { Task { await model.install(package) } } }
                        if let addon {
                            Button(model.installed(addon.id) == nil ? "只更新词库（\(addon.version)）" : "重新更新词库") { Task { await model.install(addon) } }
                        }
                        Button("卸载", role: .destructive) { model.uninstall(package) }
                    } label: { Text("管理") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }

    private func conflictNames(_ package: DictionaryPackage) -> String? {
        let names = (package.conflicts ?? []).compactMap { model.registry.package($0)?.title }
            .filter { !card.map(\.title).contains($0) }
        return names.isEmpty ? nil : "「" + names.joined(separator: "」「") + "」"
    }

    private func install(_ package: DictionaryPackage) {
        if (package.conflicts ?? []).contains(where: { model.installed($0) != nil }) { confirm = package }
        else { Task { await model.install(package) } }
    }
}

private struct AddonRow: View {
    @Environment(SettingsModel.self) private var model
    let package: DictionaryPackage

    var body: some View {
        let installed = model.installed(package.id)
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(package.title).font(.body.weight(.medium))
                    if package.kind != .model {
                        Text(package.version).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Text(package.audience ?? package.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if package.kind == .model {
                    HStack(spacing: 10) {
                        if let size = package.size { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
                        Text(package.license)
                        if installed != nil { Label("已安装", systemImage: "checkmark.circle") }
                    }.font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.packageActivity[package.id] != nil {
                ProgressView().controlSize(.small)
            } else if installed == nil {
                Button(package.kind == .model ? "下载并安装" : "安装") { Task { await model.install(package) } }.controlSize(.small)
            } else {
                if package.kind == .model && installed?.version != package.version {
                    Button("更新") { Task { await model.install(package) } }.controlSize(.small)
                }
                Button("卸载", role: .destructive) { model.uninstall(package) }.controlSize(.small)
            }
        }
    }
}

// MARK: - Phrases

struct PhrasesView: View {
    @Environment(SettingsModel.self) private var model
    @State private var search = ""
    @State private var newText = ""
    @State private var newCode = ""
    @State private var selection = Set<CustomPhrases.Phrase.ID>()

    var body: some View {
        @Bindable var model = model
        let filtered = model.phrases.phrases.filter {
            search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || $0.code.contains(search.lowercased())
        }
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "自定义短语", subtitle: "置顶的词条：邮箱、手机号、常用签名……编码可以任意起，不限于拼音。", symbol: "text.quote")
            HStack(spacing: 10) {
                Picker("短语表", selection: Binding(
                    get: { model.phraseTable },
                    set: { model.selectPhraseTable($0) }
                )) {
                    ForEach(model.phraseTables) { table in
                        Text(tableTitle(table)).tag(table)
                    }
                }
                .frame(maxWidth: 360)
                Spacer()
                Menu {
                    Button("从鼠须管导入（合并）") {
                        model.importPhrases(from: AIMEPaths.squirrelUserDir.appendingPathComponent(model.phraseTable.fileName))
                    }
                    .disabled(!FileManager.default.fileExists(atPath: AIMEPaths.squirrelUserDir.appendingPathComponent(model.phraseTable.fileName).path))
                    Button("从文件导入…") { choosePhraseFile() }
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                .fixedSize()
            }
            if let notice = model.phraseNotice {
                Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(Theme.success)
            }
            HStack(spacing: 8) {
                TextField("词条", text: $newText).textFieldStyle(.roundedBorder).frame(minWidth: 200)
                TextField("编码", text: $newCode).textFieldStyle(.roundedBorder).frame(width: 140)
                Button {
                    model.updatePhrases { $0.add(.init(text: newText, code: newCode.lowercased())) }
                    newText = ""; newCode = ""
                } label: { Label("添加", systemImage: "plus") }
                    .disabled(!CustomPhrases.Phrase(text: newText, code: newCode.lowercased()).isValid)
                Spacer()
                TextField("搜索", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            Table(filtered, selection: $selection) {
                TableColumn("词条") { phrase in Text(phrase.text) }
                TableColumn("编码") { phrase in Text(phrase.code).font(.body.monospaced()) }.width(140)
                TableColumn("权重") { phrase in Text(phrase.weight.map(String.init) ?? "—").foregroundStyle(.secondary) }.width(60)
            }
            .contextMenu(forSelectionType: CustomPhrases.Phrase.ID.self) { ids in
                Button("删除", role: .destructive) { model.updatePhrases { $0.phrases.removeAll { ids.contains($0.id) } } }
            }
            HStack {
                Text("\(model.phrases.phrases.count) 条 · \(model.store.phraseTableURL(model.phraseTable).path)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("删除所选", role: .destructive) {
                    model.updatePhrases { $0.phrases.removeAll { selection.contains($0.id) } }
                    selection.removeAll()
                }
                .disabled(selection.isEmpty)
                Button("保存") { model.savePhrases() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.phrasesDirty)
                    .keyboardShortcut("s")
            }
        }
        .paneColumn()
    }
}

extension PhrasesView {
    func tableTitle(_ table: PhraseTable) -> String {
        let kind = table.name.contains("double") ? "双拼" : table.name == "custom_phrase" ? "全拼" : table.name
        let schemas = table.schemas.isEmpty ? "" : " · \(table.schemas.joined(separator: "、"))"
        return "\(kind)（\(table.fileName)）\(schemas)"
    }

    func choosePhraseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .tabSeparatedText]
        panel.directoryURL = AIMEPaths.squirrelUserDir
        panel.prompt = "导入"
        panel.message = "选择 Rime 短语表（词条<Tab>编码<Tab>权重），重复的词条会自动跳过"
        if panel.runModal() == .OK, let url = panel.url { model.importPhrases(from: url) }
    }
}

// MARK: - Sync

struct SyncView: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        Form {
            Section { PaneHeader(title: "同步与备份", subtitle: "在多台 Mac 之间合并用户词频；或把全部配置备份成一个文件，换机、重装时一键恢复。", symbol: "arrow.triangle.2.circlepath") }

            Section("同步目录") {
                LabeledContent("位置") {
                    Text(model.syncDir ?? "默认（用户目录/sync）").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Button("选择文件夹…") { choose() }
                    Button("使用 iCloud Drive") {
                        let iCloud = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/AIME/sync")
                        try? FileManager.default.createDirectory(at: iCloud, withIntermediateDirectories: true)
                        model.setSyncDir(iCloud.path)
                    }
                    Button("恢复默认") { model.setSyncDir(nil) }.disabled(model.syncDir == nil)
                }
                if let id = model.installationID {
                    LabeledContent("本机标识") { Text(id).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("立即同步").font(.body.weight(.medium))
                        Text("导出本机词频快照到同步目录，并合并其他设备的快照。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("同步") { Task { await model.syncNow() } }.disabled(model.deployState == .deploying)
                }
            }
            BackupSection()
        }
        .formStyle(.cards)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url { model.setSyncDir(url.path) }
    }
}

/// 备份与恢复: one local file with everything the user made; restore asks first and keeps
/// a safety copy of the current state.
private struct BackupSection: View {
    @Environment(SettingsModel.self) private var model
    @State private var includeStats = false
    @State private var pending: BackupManager.Opened?

    var body: some View {
        Section {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("备份到文件").font(.body.weight(.medium))
                    Text("设置与手写配置、常用语与短语、词库订阅、自己的方案与词典、学到的词频。").font(.caption).foregroundStyle(.secondary)
                    Toggle("同时备份输入统计", isOn: $includeStats).toggleStyle(.checkbox).font(.caption).labeledContentStyle(.automatic)
                }
                Spacer()
                Button("备份…", action: backup).disabled(model.backupActivity != nil)
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("从备份恢复").font(.body.weight(.medium))
                    Text("恢复前会先把当前配置自动备份一份，随时可以退回。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("恢复…", action: chooseBackup).disabled(model.backupActivity != nil)
            }
            if let activity = model.backupActivity {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(activity).font(.caption).foregroundStyle(.secondary) }
            } else if let notice = model.backupNotice {
                Label(notice, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.success)
            }
        } header: {
            HStack {
                Text("备份与恢复")
                Spacer()
                if FileManager.default.fileExists(atPath: model.backupManager.safetyDirectory.path) {
                    Button { NSWorkspace.shared.open(model.backupManager.safetyDirectory) } label: { Label("自动备份", systemImage: "folder") }
                        .buttonStyle(.borderless).controlSize(.small)
                        .help("恢复前自动保存的备份")
                }
            }
        } footer: {
            Text("备份只写到你选择的位置，不上传任何地方。不包含 API Key、可重新生成的编译文件和随 App 附带的词库。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: Binding(get: { pending.map(PendingBackup.init) }, set: { if $0 == nil { pending = nil } })) { item in
            RestoreConfirmation(manifest: item.opened.manifest) {
                let opened = item.opened
                pending = nil
                Task { await model.restoreBackup(opened) }
            } cancel: {
                model.closeBackup(item.opened)
                pending = nil
            }
        }
    }

    private struct PendingBackup: Identifiable {
        let opened: BackupManager.Opened
        var id: Date { opened.manifest.created }
    }

    private func backup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = BackupManager.suggestedName()
        if let type = UTType(filenameExtension: BackupManager.fileExtension) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let stats = includeStats
        Task { await model.createBackup(to: url, includeStats: stats) }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: BackupManager.fileExtension) { panel.allowedContentTypes = [type, .zip] }
        panel.prompt = "检查备份"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pending = model.openBackup(url)
    }
}

/// What a backup holds, before anything is replaced.
private struct RestoreConfirmation: View {
    let manifest: BackupManager.Manifest
    let restore: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("从备份恢复", systemImage: "clock.arrow.circlepath").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                row("备份时间", manifest.created.formatted(date: .long, time: .shortened))
                if let version = manifest.appVersion { row("来自版本", version) }
                row("设置与订阅", "\(manifest.settingsCount) 个文件")
                row("短语表", "\(manifest.phraseCount) 个")
                row("词频快照", manifest.frequencyCount > 0 ? "\(manifest.frequencyCount) 个（恢复后自动合并）" : "无")
                row("输入统计", manifest.includesStats ? "\(manifest.statsCount) 个文件" : "未包含")
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("当前的设置、短语和订阅会被替换。恢复前会自动备份当前配置，放在「自动备份」文件夹里。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("恢复", action: restore).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.callout)
    }
}

extension View {
    /// Screenshot automation: `--scroll-to <id>` scrolls the pane to that anchor.
    func scrollTargetForScreenshots() -> some View {
        modifier(ScreenshotScroll())
    }
}

private struct ScreenshotScroll: ViewModifier {
    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onAppear {
                guard let target = LaunchOptions.argument("--scroll-to") else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { proxy.scrollTo(target, anchor: .top) }
            }
        }
    }
}
