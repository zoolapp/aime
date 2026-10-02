import AIMEAI
import AIMECore
import AIMEPanel
import AppKit
import Carbon
import Observation

/// Single source of state for the settings window. Reads deployed values through
/// `SettingsStore`, writes into the generated layer, and asks the input method (or the
/// bundled CLI) to deploy.
@MainActor
@Observable
final class SettingsModel {
    enum DeployState: Equatable {
        case idle
        case deploying
        case succeeded(Date)
        case failed(String)
    }

    let paths: AIMEPaths
    let store: SettingsStore
    let catalog: SettingCatalog
    let registry = DictionaryRegistry.bundled
    let deployer: DeployService

    /// Bumped after every write so views re-read values.
    private(set) var revision = 0
    /// Any write marks changes pending; they are applied automatically shortly after.
    private(set) var hasPendingChanges = false {
        didSet { if hasPendingChanges { changeCount += 1; scheduleAutoDeploy() } }
    }
    private(set) var deployState: DeployState = .idle
    /// 0…1 while a deploy runs (estimated from the previous duration), nil otherwise.
    private(set) var deployProgress: Double?
    /// What the input method is doing right now, e.g. "正在编译 2 个方案…".
    private(set) var deployStage = ""
    private var changeCount = 0
    private var autoDeployTask: Task<Void, Never>?
    private(set) var lastError: String?

    var phrases: CustomPhrases
    private(set) var phrasesDirty = false
    /// Which phrase table the phrases page edits (全拼 custom_phrase / 双拼 custom_phrase_double…).
    private(set) var phraseTable = PhraseTable(name: "custom_phrase", schemas: [])
    private(set) var phraseNotice: String?

    /// Package id → in-flight status text.
    private(set) var packageActivity: [String: String] = [:]
    /// Progress text while a vocabulary subscription is being fetched.
    private(set) var subscriptionActivity: String?

    init() {
        var paths = AIMEPaths.standard
        paths.sharedDataDir = Locations.sharedSupport
        self.paths = paths
        self.store = SettingsStore(paths: paths)
        self.catalog = store.catalog
        self.deployer = DeployService(paths: paths)
        // Open the phrase table the enabled schemas actually use (双拼 uses custom_phrase_double).
        let table = store.phraseTables().first { !$0.schemas.isEmpty } ?? PhraseTable(name: "custom_phrase", schemas: [])
        self.phraseTable = table
        self.phrases = CustomPhrases.load(from: store.phraseTableURL(table))
        hasPendingChanges = !ConfigLayers(paths: paths).dirtyTargets().isEmpty
        // Changes left from a previous session are applied right away.
        if hasPendingChanges { scheduleAutoDeploy() }
    }

    // MARK: - Status

    var isInstalled: Bool { Locations.inputMethodApp != nil }

    /// Whether the AIME input mode is enabled in System Settings › Keyboard › Input Sources.
    var isInputSourceEnabled: Bool {
        _ = revision
        let filter = [kTISPropertyInputSourceID as String: "app.zool.inputmethod.aime.hans"] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first, let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled)
        else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }
    var isDeployed: Bool { FileManager.default.fileExists(atPath: paths.builtConfig("default").path) }
    var enabledSchemas: [String] { _ = revision; return store.pendingSchemas() }
    var availableSchemas: [SchemaInfo] { _ = revision; return SchemaDiscovery.available(paths: paths) }
    var squirrelDirExists: Bool { FileManager.default.fileExists(atPath: AIMEPaths.squirrelUserDir.path) }
    var importReport: URL { paths.aimeDir.appendingPathComponent("import-report.json") }
    var hasImported: Bool { FileManager.default.fileExists(atPath: importReport.path) }

    // MARK: - Settings

    func value(_ setting: SettingCatalog.Setting) -> ConfigValue? {
        _ = revision
        return store.value(for: setting)
    }

    func isCustomized(_ setting: SettingCatalog.Setting) -> Bool {
        _ = revision
        return store.isCustomized(setting)
    }

    func set(_ value: ConfigValue, for setting: SettingCatalog.Setting) {
        perform { try store.set(value, for: setting) }
    }

    func reset(_ setting: SettingCatalog.Setting) {
        perform { try store.reset(setting) }
    }

    func setting(_ id: String) -> SettingCatalog.Setting? { catalog.setting(id) }

    func setEnabledSchemas(_ ids: [String]) {
        perform { try store.setEnabledSchemas(ids) }
    }

    /// Switch options of the primary schema, for multi-select controls.
    var availableSwitches: [(name: String, title: String)] {
        _ = revision
        guard let schema = enabledSchemas.first,
              let switches = store.built(.schema(schema))?.value(at: "switches")?.listValue else { return [] }
        let known = ["ascii_mode": "中英文", "full_shape": "全角", "ascii_punct": "英文标点", "traditionalization": "繁体",
                     "emoji": "Emoji", "search_single_char": "单字优先", "simplification": "简化字"]
        return switches.compactMap { item -> (String, String)? in
            guard let name = item["name"]?.stringValue else { return nil }
            let states = item["states"]?.listValue?.compactMap(\.stringValue) ?? []
            return (name, known[name] ?? (states.last ?? name))
        }
    }

    /// `.gram` language models available in the user and shared data directories.
    var gramModels: [String] {
        let dirs = [paths.userDataDir, paths.sharedDataDir].compactMap { $0 }
        let names = dirs.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }
        return Array(Set(names.filter { $0.hasSuffix(".gram") }.map { String($0.dropLast(5)) })).sorted()
    }

    var appOptions: [SettingsStore.AppOption] { _ = revision; return store.appOptions() }

    func setAppOption(_ option: SettingsStore.AppOption) { perform { try store.setAppOption(option) } }
    func removeAppOption(_ bundleID: String) { perform { try store.removeAppOption(bundleID) } }

    // MARK: - 智能配置 (recommended per-app options)

    enum AppScanPhase: Equatable {
        case idle
        case scanning(fraction: Double, name: String, path: String?)
        case review
        case applied(Int)
    }

    private(set) var appScanPhase: AppScanPhase = .idle
    private(set) var appSuggestions: [AppRecommendations.Suggestion] = []

    /// Scans installed apps and proposes options from the recommendation rules; nothing
    /// is written until `applyAppSuggestions()`.
    func scanInstalledApps() async {
        guard appScanPhase == .idle || appScanPhase == .review || { if case .applied = appScanPhase { true } else { false } }() else { return }
        appSuggestions = []
        appScanPhase = .scanning(fraction: 0, name: "", path: nil)
        let apps = await AppScanner.scan { [weak self] fraction, app in
            self?.appScanPhase = .scanning(fraction: fraction, name: app.name, path: app.url?.path)
        }
        let existing = Set(store.appOptions().map(\.bundleID))
        appSuggestions = AppRecommendations.load(paths).suggestions(for: apps, existing: existing)
        appScanPhase = .review
    }

    /// Apps that already have options (shown as "kept" in onboarding).
    var configuredAppCount: Int { _ = revision; return store.appOptions().count }

    func toggleAppSuggestion(_ id: String) {
        guard let index = appSuggestions.firstIndex(where: { $0.id == id }) else { return }
        appSuggestions[index].selected.toggle()
    }

    /// Changing the mode of a row also ticks it: the user evidently wants it applied.
    func setAppSuggestionMode(_ id: String, _ mode: SettingsStore.AppOption.InitialMode) {
        guard let index = appSuggestions.firstIndex(where: { $0.id == id }) else { return }
        appSuggestions[index].initialMode = mode
        appSuggestions[index].selected = true
    }

    func applyAppSuggestions() {
        let chosen = appSuggestions.filter(\.selected)
        perform { for suggestion in chosen { try store.setAppOption(suggestion.option) } }
        appSuggestions = []
        appScanPhase = .applied(chosen.count)
    }

    func dismissAppScan() {
        appSuggestions = []
        appScanPhase = .idle
    }

    /// Runs a write, records pending state and refreshes views.
    func perform(_ body: () throws -> Void) {
        do {
            try body()
            hasPendingChanges = true
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        revision += 1
    }

    // MARK: - Appearance

    var previewFrontend: ConfigValue { _ = revision; return store.previewFrontend() }

    func theme(dark: Bool, scheme: String? = nil) -> PanelTheme {
        PanelTheme(frontend: previewFrontend, dark: dark, schemeOverride: scheme)
    }

    var colorSchemes: [(id: String, name: String)] { PanelTheme.schemeNames(in: previewFrontend) }

    static let customSchemeID = "aime_custom"

    /// Copies a scheme into the editable `aime_custom` scheme and selects it.
    func customizeScheme(from base: PanelTheme) {
        let colors: [(String, ThemeColor)] = [
            ("back_color", base.backColor), ("border_color", base.borderColor),
            ("preedit_back_color", base.preeditBackColor), ("text_color", base.textColor),
            ("hilited_text_color", base.hilitedTextColor), ("hilited_back_color", base.hilitedBackColor),
            ("candidate_text_color", base.candidateTextColor), ("comment_text_color", base.commentTextColor),
            ("label_color", base.labelColor), ("hilited_candidate_back_color", base.hilitedCandidateBackColor),
            ("hilited_candidate_text_color", base.hilitedCandidateTextColor),
            ("hilited_comment_text_color", base.hilitedCommentTextColor),
            ("hilited_candidate_label_color", base.hilitedCandidateLabelColor),
        ]
        let scheme = ConfigValue.map(
            [.init("name", "我的配色"), .init("author", "AIME Settings"), .init("color_format", "argb")]
                + colors.map { .init($0.0, .string($0.1.argbString)) }
        )
        perform {
            try store.layers.updateGenerated(.frontend) { patch in
                patch.removeAll { $0.key.hasPrefix("preset_color_schemes/\(Self.customSchemeID)") }
                patch.append(.init("preset_color_schemes/\(Self.customSchemeID)", scheme))
                patch.removeAll { $0.key == "style/color_scheme" || $0.key == "style/color_scheme_dark" }
                patch.append(.init("style/color_scheme", .string(Self.customSchemeID)))
                patch.append(.init("style/color_scheme_dark", .string(Self.customSchemeID)))
            }
        }
    }

    // MARK: - Theme links (aime-ime://theme, docs/themes.md)

    /// Links waiting for confirmation, shown one at a time.
    private(set) var themeImports: [ThemePackage.Decoded] = []
    private(set) var themeImportError: String?
    private(set) var themeNotice: String?

    /// Validates an `aime-ime://theme` link and queues it; nothing is written until the
    /// user confirms in the import sheet.
    func receiveThemeLink(_ url: URL) {
        do {
            let decoded = try ThemePackage.decode(url: url)
            guard !themeImports.contains(where: { $0.package == decoded.package }) else { return }
            themeImports.append(decoded)
            themeImportError = nil
        } catch {
            themeImportError = error.localizedDescription
        }
    }

    func themeImportPlan(_ package: ThemePackage) -> ThemeImportPlan {
        ThemeImportPlan(package: package, frontend: previewFrontend,
                        generatedPatch: (try? store.layers.generatedPatch(.frontend)) ?? [])
    }

    /// How a package would render with the user's own layout and font.
    /// With `adoptLayout`, the theme's radii, padding and font sizes replace the user's
    /// own panel settings, as they would after importing.
    func theme(for package: ThemePackage, dark: Bool, adoptLayout: Bool = false) -> PanelTheme {
        var frontend = previewFrontend
        frontend.set(package.schemeValue, at: "preset_color_schemes/\(package.id)")
        if adoptLayout, let layout = package.layout {
            for (key, value) in layout { frontend.set(.double(value), at: "style/aime/\(key)") }
        }
        return PanelTheme(frontend: frontend, dark: dark, schemeOverride: package.id)
    }

    func confirmThemeImport(activate: Bool, target: ThemeImportPlan.Target, adoptLayout: Bool = false) {
        guard let decoded = themeImports.first else { return }
        let plan = themeImportPlan(decoded.package)
        perform {
            try store.layers.updateGenerated(.frontend) { patch in
                plan.apply(to: &patch, activate: activate, target: target, adoptLayout: adoptLayout)
            }
        }
        themeNotice = plan.isBuiltIn ? "已切换到内置主题「\(decoded.package.name)」"
            : activate ? "已导入并启用「\(decoded.package.name)」" : "已导入「\(decoded.package.name)」，可在外观中选择"
        themeImports.removeFirst()
    }

    func cancelThemeImport() {
        if !themeImports.isEmpty { themeImports.removeFirst() }
    }

    func dismissThemeImportError() { themeImportError = nil }
    func dismissThemeNotice() { themeNotice = nil }

    // MARK: - Deploy

    /// Coalesces bursts of edits (slider drags, several toggles) into one deploy.
    private var autoDeployPauses = 0

    /// Holds automatic deploys while a change is still being validated (advanced YAML).
    func pauseAutoDeploy() {
        autoDeployPauses += 1
        autoDeployTask?.cancel()
    }

    func resumeAutoDeploy() {
        autoDeployPauses = max(0, autoDeployPauses - 1)
        if autoDeployPauses == 0, hasPendingChanges { scheduleAutoDeploy() }
    }

    private func scheduleAutoDeploy() {
        autoDeployTask?.cancel()
        guard autoDeployPauses == 0 else { return }
        autoDeployTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            await self.deploy(automatic: true)
        }
    }

    /// Applies pending changes. Automatic deploys are incremental (appearance changes
    /// reload in milliseconds); the manual 重新部署 rebuilds everything.
    func deploy(automatic: Bool = false) async {
        // Deploys run one after another; a request made meanwhile waits for its turn.
        let previous = deployChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.performDeploy(automatic: automatic)
        }
        deployChain = task
        await task.value
    }

    private var deployChain: Task<Void, Never>?
    /// Phrase tables are read when librime builds a session: after editing them, the
    /// appearance-only fast path is not enough and the sessions must be recreated.
    @ObservationIgnored private var needsEngineReload = false

    private func performDeploy(automatic: Bool) async {
        // An automatic pass queued behind another may find nothing left to apply.
        if automatic, !hasPendingChanges { return }
        let startedWith = changeCount
        deployState = .deploying
        deployStage = "正在保存设置…"
        let started = Date()
        let expected = max(0.3, UserDefaults.standard.double(forKey: automatic ? "deploy.lastAutoDuration" : "deploy.lastDuration"))
        deployProgress = 0.05
        let ticker = Task { [weak self] in
            // Eases toward 90 % over the expected duration; the result jumps to 100 %.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.deployState == .deploying else { return }
                let t = Date().timeIntervalSince(started) / (expected == 0.3 ? 2.5 : expected)
                self.deployProgress = 0.05 + 0.85 * (1 - exp(-2.2 * t))
            }
        }
        let reload = needsEngineReload
        needsEngineReload = false
        let result = await deployer.deploy(automatic: automatic && !reload) { [weak self] stage, total in
            self?.deployStage = switch stage {
            case "frontend": "正在应用外观…"
            case "schemas" where total > 0: "正在编译 \(total) 个配置…"
            default: "正在部署…"
            }
        }
        ticker.cancel()
        UserDefaults.standard.set(Date().timeIntervalSince(started), forKey: automatic ? "deploy.lastAutoDuration" : "deploy.lastDuration")
        switch result {
        case .success:
            deployState = .succeeded(Date())
            deployProgress = 1
            if changeCount == startedWith { hasPendingChanges = false }
        case let .failure(message):
            deployState = .failed(message)
            deployProgress = nil
            if reload { needsEngineReload = true }
        }
        deployStage = ""
        revision += 1
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            if self?.deployState != .deploying { self?.deployProgress = nil }
        }
        // Edits made while deploying get their own pass.
        if changeCount != startedWith, case .succeeded = deployState { scheduleAutoDeploy() }
    }

    var phraseTables: [PhraseTable] { _ = revision; return store.phraseTables() }

    func selectPhraseTable(_ table: PhraseTable) {
        if phrasesDirty { savePhrases() }
        phraseTable = table
        phrases = CustomPhrases.load(from: store.phraseTableURL(table))
        phraseNotice = nil
    }

    /// Merges phrases from a table file into the current table (duplicates skipped).
    func importPhrases(from url: URL) {
        if phrasesDirty { savePhrases() }
        do {
            let result = try store.importPhrases(from: url, into: phraseTable)
            phrases = CustomPhrases.load(from: store.phraseTableURL(phraseTable))
            phraseNotice = "已导入 \(result.added) 条，跳过 \(result.skipped) 条重复或无效"
            if result.added > 0 { needsEngineReload = true; hasPendingChanges = true }
        } catch {
            lastError = String(describing: error)
        }
        revision += 1
    }

    /// Plan of a RIME directory import (dry run), shown before importing.
    func importPlan(from source: URL) -> [SquirrelImporter.Action] {
        (try? SquirrelImporter(paths: paths, source: source).plan().actions) ?? []
    }

    func importSquirrel(from source: URL = AIMEPaths.squirrelUserDir) async {
        deployState = .deploying
        let result = await deployer.run(["import-squirrel", "--from", source.path])
        deployState = result.ok ? .succeeded(Date()) : .failed(result.output.suffix(400).description)
        phrases = CustomPhrases.load(from: store.phraseTableURL(phraseTable))
        if result.ok { hasPendingChanges = false }
        revision += 1
    }

    // MARK: - Phrases

    func updatePhrases(_ body: (inout CustomPhrases) -> Void) {
        body(&phrases)
        phrasesDirty = true
    }

    func savePhrases() {
        do {
            try phrases.save(to: store.phraseTableURL(phraseTable))
            phrasesDirty = false
            needsEngineReload = true
            hasPendingChanges = true
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Packages

    func installed(_ id: String) -> InstalledPackage? { _ = revision; return PackageManager(paths: paths).installed(id) }

    /// Installs a scheme after removing the packages it replaces (asked for in the UI).
    func installReplacing(_ package: DictionaryPackage) async {
        for id in package.conflicts ?? [] where installed(id) != nil {
            perform { _ = try PackageManager(paths: paths).uninstall(id) }
        }
        await install(package)
    }

    /// Makes `schema` the primary (first) enabled schema — what new sessions type with.
    func makePrimary(_ schema: String) {
        setEnabledSchemas([schema] + enabledSchemas.filter { $0 != schema })
    }

    func install(_ package: DictionaryPackage) async {
        packageActivity[package.id] = "准备下载…"
        let manager = PackageManager(paths: paths)
        do {
            try await manager.install(package.id) { message in
                Task { @MainActor in self.packageActivity[package.id] = message }
            }
            packageActivity[package.id] = nil
            hasPendingChanges = true
        } catch {
            packageActivity[package.id] = nil
            lastError = "\(package.title)：\(error)"
        }
        revision += 1
    }

    func uninstall(_ package: DictionaryPackage) {
        perform { _ = try PackageManager(paths: paths).uninstall(package.id) }
    }

    // MARK: - Subscribed vocabularies

    var subscriptions: [VocabularySubscription] { _ = revision; return SubscriptionManager(paths: paths).subscriptions() }

    /// Official feeds (aime.zool.app catalog; cached, refreshed once per launch or on demand).
    private(set) var vocabularyCatalog: VocabularyCatalog?
    private var catalogRefreshed = false
    private(set) var catalogRefreshing = false
    private(set) var catalogError: String?

    func loadVocabularyCatalog(force: Bool = false) async {
        if vocabularyCatalog == nil { vocabularyCatalog = VocabularyCatalog.load(paths) }
        guard force || !catalogRefreshed else { return }
        catalogRefreshed = true
        catalogRefreshing = true
        defer { catalogRefreshing = false }
        do {
            let fresh = try await VocabularyCatalog.refresh(paths)
            vocabularyCatalog = fresh
            catalogError = nil
            // Subscriptions from the catalog point at its current files right away.
            if (try? SubscriptionManager(paths: paths).follow(fresh))?.isEmpty == false { revision += 1 }
        } catch {
            catalogError = "无法获取在线目录，显示的是缓存或内置版本"
        }
    }

    func setSubscriptionInterval(_ id: String, _ interval: VocabularySubscription.UpdateInterval) {
        do { try SubscriptionManager(paths: paths).setInterval(id: id, interval) } catch { lastError = String(describing: error) }
        revision += 1
    }

    /// e.g. "rime-ice 2026.06.30" from SharedSupport/aime/VERSION.
    var baseDictionaryVersion: String? {
        guard let url = paths.sharedDataDir?.appendingPathComponent("aime/VERSION"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let name = text.split(separator: " ").last.map(String.init) ?? text
        return name.replacingOccurrences(of: "rime-ice-", with: "").replacingOccurrences(of: "-full.zip", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds a feed, downloads it and redeploys so the words are typable right away.
    /// Returns false (and removes the entry) when nothing usable was downloaded.
    @discardableResult
    func addSubscription(url: String, name: String?, feed: VocabularyCatalog.Feed? = nil) async -> Bool {
        subscriptionActivity = "正在下载…"
        defer { subscriptionActivity = nil; revision += 1 }
        let manager = SubscriptionManager(paths: paths)
        do {
            let item = try await manager.add(url: url, name: name, feed: feed)
            if let error = item.lastError {
                try? manager.remove(id: item.id)
                lastError = "订阅失败：\(error)"
                return false
            }
        } catch {
            lastError = "订阅失败：\(error)"
            return false
        }
        lastError = nil
        await deploy()
        return true
    }

    func refreshSubscriptions() async {
        subscriptionActivity = "正在检查更新…"
        let manager = SubscriptionManager(paths: paths)
        for item in manager.subscriptions() { _ = try? await manager.update(id: item.id, force: true) }
        subscriptionActivity = nil
        revision += 1
        await deploy()
    }

    func removeSubscription(_ id: String) async {
        do { try SubscriptionManager(paths: paths).remove(id: id) } catch { lastError = String(describing: error) }
        revision += 1
        await deploy()
    }

    // MARK: - 常用语 (snippets)

    var snippets: Snippets { _ = revision; return Snippets.load(paths) }

    /// Saves right away; the input method reads the file when the quick menu opens, so
    /// no deploy is needed.
    func updateSnippets(_ body: (inout Snippets) -> Void) {
        var value = Snippets.load(paths)
        body(&value)
        do { try value.save(paths) } catch { lastError = String(describing: error) }
        revision += 1
    }

    // MARK: - Usage statistics

    let statsStore = UsageStatsStore()
    var features: AIMEFeatures { _ = revision; return AIMEFeatures.load(paths) }

    func setUsageStats(_ enabled: Bool) { updateFeatures { $0.usageStats = enabled } }

    /// Writes aime/features.json and tells the input method to reload it.
    func updateFeatures(_ body: (inout AIMEFeatures) -> Void) {
        var features = AIMEFeatures.load(paths)
        let before = features
        body(&features)
        // Consent to send text is given for one host; a new endpoint needs it again.
        if URL(string: features.aiBaseURL)?.host() != URL(string: before.aiBaseURL)?.host() { features.aiRemoteAllowed = false }
        guard features != before else { return }
        do {
            try features.save(paths)
            DistributedNotificationCenter.default().postNotificationName(
                AIMEFeatures.changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
        } catch {
            lastError = String(describing: error)
        }
        revision += 1
    }

    func usageSummary(days: Int) -> UsageSummary { _ = revision; _ = statsRevision; return statsStore.summary(days: days) }

    /// Bumped to re-read the statistics files (the input method writes them every few minutes).
    private(set) var statsRevision = 0
    @ObservationIgnored private var cachedReport: (revision: Int, report: ActivityReport)?

    func refreshStats() { statsRevision += 1 }

    /// 输入统计: totals, series and breakdowns, read once per refresh.
    func activityReport() -> ActivityReport {
        let key = revision &* 1_000_003 &+ statsRevision
        if let cachedReport, cachedReport.revision == key { return cachedReport.report }
        let report = statsStore.report()
        cachedReport = (key, report)
        return report
    }

    func clearUsageStats() {
        statsStore.clear()
        DistributedNotificationCenter.default().postNotificationName(
            UsageStatsStore.clearedNotification, object: nil, userInfo: nil, deliverImmediately: true)
        revision += 1
    }

    func blockUsageWord(_ word: String) {
        do { try statsStore.block(word) } catch { lastError = String(describing: error) }
        revision += 1
    }

    /// The code a word gets in the active phrase table: 双拼 tables use 双拼 codes, so
    /// pinned words and AI-extracted terms are typeable in the schema that reads them.
    func phraseCode(_ word: String) -> String? {
        guard let pinyin = VocabularyParser.pinyin(for: word) else { return nil }
        let layout = phraseTable.schemas.lazy.compactMap(DoublePinyin.layout(forSchema:)).first
        return layout?.code(forPinyin: pinyin) ?? pinyin.replacingOccurrences(of: " ", with: "")
    }

    func pinUsageWord(_ word: String) -> String? {
        guard let code = phraseCode(word) else { return nil }
        updatePhrases { _ = $0.add(.init(text: word, code: code)) }
        savePhrases()
        revision += 1
        return code
    }

    func isPinned(_ word: String) -> Bool { phrases.phrases.contains { $0.text == word } }

    /// Removes the entry pinning added. A phrase the user wrote by hand under another
    /// code is left alone (returns false so the view can point to 自定义短语).
    func unpinUsageWord(_ word: String) -> Bool {
        guard let code = phraseCode(word), phrases.phrases.contains(where: { $0.text == word && $0.code == code }) else { return false }
        updatePhrases { $0.remove(text: word, code: code) }
        savePhrases()
        revision += 1
        return true
    }

    // MARK: - Sync

    var syncDir: String? { _ = revision; return store.syncDir }
    var installationID: String? { _ = revision; return store.installationInfo()["installation_id"]?.stringValue }

    func setSyncDir(_ path: String?) { perform { try store.setSyncDir(path) } }

    @discardableResult
    func syncNow() async -> Bool {
        deployState = .deploying
        let outcome = await deployer.sync()
        switch outcome {
        case .success: deployState = .succeeded(Date())
        case let .failure(message): deployState = .failed(message)
        }
        revision += 1
        return outcome == .success
    }

    // MARK: - Backup (local only)

    private(set) var backupActivity: String?
    private(set) var backupNotice: String?
    var backupManager: BackupManager { BackupManager(paths: paths, statsDirectory: statsStore.directory) }

    /// Exports fresh frequency snapshots (RIME sync), then writes the backup file.
    func createBackup(to url: URL, includeStats: Bool) async {
        backupActivity = "正在导出词频快照…"
        let synced = await syncNow()
        backupActivity = "正在打包…"
        defer { backupActivity = nil }
        let manager = backupManager
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        do {
            let manifest = try await Task.detached { try manager.create(at: url, includeStats: includeStats, appVersion: version) }.value
            backupNotice = synced
                ? "已备份 \(manifest.files.count) 个文件到 \(url.lastPathComponent)"
                : "已备份 \(manifest.files.count) 个文件到 \(url.lastPathComponent)，但词频同步失败，备份未包含最新词频"
        } catch {
            lastError = "备份失败：\(error)"
        }
    }

    /// Unpacks and verifies a backup; nothing changes until `restoreBackup`.
    func openBackup(_ url: URL) -> BackupManager.Opened? {
        do { return try backupManager.open(url) } catch {
            lastError = "无法读取备份：\(error)"
            return nil
        }
    }

    /// Restores, then rebuilds everything: features reload in the input method, layers
    /// and phrase tables deploy, frequency snapshots merge through RIME sync.
    func restoreBackup(_ opened: BackupManager.Opened) async {
        backupActivity = "正在恢复…"
        defer { backupActivity = nil }
        do {
            let safety = try backupManager.restore(opened)
            backupNotice = "已恢复。恢复前的配置已自动备份为「\(safety.lastPathComponent)」"
        } catch {
            lastError = "恢复失败：\(error)"
            return
        }
        DistributedNotificationCenter.default().postNotificationName(
            AIMEFeatures.changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
        let table = store.phraseTables().first { !$0.schemas.isEmpty } ?? PhraseTable(name: "custom_phrase", schemas: [])
        phraseTable = table
        phrases = CustomPhrases.load(from: store.phraseTableURL(table))
        needsEngineReload = true
        hasPendingChanges = true
        revision += 1
        await deploy()
        await syncNow()
    }

    func closeBackup(_ opened: BackupManager.Opened) { backupManager.close(opened) }

    func dismissError() { lastError = nil }

    // MARK: - App updates

    let currentVersion = AppVersion.current()
    private(set) var updateState = AppUpdateState()
    private(set) var updateChecking = false
    /// 0…1 while the installer downloads.
    private(set) var updateProgress: Double?
    private(set) var updateNotice: String?
    /// Ad-hoc development builds (install-dev.sh) are not offered releases.
    let isDistributionBuild = AppVersion.isDistributionBuild()
    var pendingUpdate: AppRelease? { isDistributionBuild ? updateState.pending(current: currentVersion) : nil }

    /// Reads the shared state and checks when a daily check is due (the input method
    /// usually has done it already).
    func refreshUpdates() async {
        updateState = AppUpdateState.load(paths)
        if isDistributionBuild, updateState.isDue() { await checkForUpdates(userInitiated: false) }
    }

    func checkForUpdates(userInitiated: Bool) async {
        guard !updateChecking else { return }
        updateChecking = true
        defer { updateChecking = false }
        if userInitiated { updateNotice = nil }
        do {
            let release = try await AppUpdateChecker().check(paths: paths, current: currentVersion)
            updateState = AppUpdateState.load(paths)
            if userInitiated, !isDistributionBuild {
                updateNotice = release.map { "开发版：最新正式版为 \($0.appVersion.description)" } ?? "开发版：没有更新的正式版"
            } else if userInitiated, release == nil { updateNotice = "已是最新版本" }
        } catch {
            if userInitiated { updateNotice = "检查失败：\(error.localizedDescription)" }
        }
    }

    func setAutoUpdate(_ on: Bool) {
        updateState.autoCheck = on
        try? updateState.save(paths)
    }

    func skipUpdate() {
        guard let release = updateState.available else { return }
        updateState.skipped = release.appVersion.description
        try? updateState.save(paths)
    }

    /// Downloads and verifies the installer (SHA-256 and Developer ID signature), then
    /// hands it to macOS Installer, which asks for the administrator password.
    func installUpdate() async {
        guard let release = pendingUpdate, updateProgress == nil else { return }
        updateNotice = nil
        updateProgress = 0
        defer { updateProgress = nil }
        let paths = paths
        do {
            let package = try await AppUpdateChecker().download(release, paths: paths) { value in
                Task { @MainActor [weak self] in if self?.updateProgress != nil { self?.updateProgress = value } }
            }
            try await Task.detached { try AppUpdateChecker.verifySignature(of: package) }.value
            NSWorkspace.shared.open(package)
            updateNotice = "已打开安装器，按提示完成更新"
        } catch {
            updateNotice = "更新失败：\(error.localizedDescription)"
        }
    }
}
