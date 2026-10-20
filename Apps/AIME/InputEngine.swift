import AIMECore
import AIMEPanel
import AppKit
import InputMethodKit
import os
import RimeKit

/// Process-wide state of the input method: librime lifecycle, the candidate panel,
/// the resolved theme and per-app options.
@MainActor
final class InputEngine {
    static let shared = InputEngine()

    static let reloadNotification = Notification.Name("app.zool.aime.reload")
    static let resultNotification = Notification.Name("app.zool.aime.deploy.result")
    static let progressNotification = Notification.Name("app.zool.aime.deploy.progress")

    let panel = CandidatePanel()
    /// Opt-in local word statistics (高频词); off unless enabled in Settings.
    let usage = UsageRecorder()
    /// aime/features.json, reloaded when Settings posts `AIMEFeatures.changedNotification`.
    private(set) var features = AIMEFeatures()
    /// Chinese/English punctuation shared by all apps, following ⌃⇧3 wherever it is
    /// pressed. Nil until the first session: it then starts from librime's remembered
    /// state when `switcher/save_options` lists ascii_punct, else from the setting.
    var asciiPunct: Bool?
    let logger = Logger(subsystem: "app.zool.aime", category: "engine")
    private(set) var paths: AIMEPaths
    private(set) var frontend: ConfigValue = .map([])
    private(set) var isDark = false
    /// Incremented on every (re)initialization so controllers can drop stale sessions.
    private(set) var generation = 0
    weak var activeController: AIMEInputController?
    /// When the user last pressed a key. Option-change bubbles are shown only for
    /// changes the user just caused, never for ones AIME makes itself (app options).
    var lastUserKeyAt = Date.distantPast
    /// Chinese/English state sharing (global / per app / per window), for the life of
    /// the process. The scope comes from `ascii_state/scope` in aime.yaml.
    var asciiState = AsciiStatePolicy()

    private var statusHideTask: Task<Void, Never>?
    /// Held from the start of a deploy until librime reports its outcome.
    private var deployLock: WorkspaceLock?
    /// Requests answered when the running deploy finishes.
    private var pendingRequests: [String?] = []
    /// Set while a deploy prepared by `runDeploy` is running (see `finishDeploy`).
    private var awaitingDeployAck = false
    /// Set while a user dictionary sync (not a deploy) holds the workspace.
    private var syncInProgress = false
    /// Requests that arrived while a deploy was running; run together afterwards.
    private var queuedRequests: [QueuedDeploy] = []
    /// An import travels with its own deploy: its snapshots are merged, and its request
    /// answered, only after that deploy (never after an unrelated one queued before it).
    private struct QueuedDeploy {
        var request: String?
        var incremental: Bool
        var importedSnapshots: [String]? = nil
    }
    private struct ImportJob {
        var requests: [String?] = []
        var snapshots: [String] = []
    }
    /// The import riding on the running deploy, if any.
    private var runningImport: ImportJob?
    private var lockRetryTask: Task<Void, Never>?
    private var frontendDeployed = true

    private init() {
        var paths = AIMEPaths.standard
        paths.sharedDataDir = Bundle.main.sharedSupportURL
        self.paths = paths
    }

    var traits: RimeTraits {
        let shared = paths.sharedDataDir ?? Bundle.main.bundleURL
        return RimeTraits(
            sharedDataDir: shared,
            userDataDir: paths.userDataDir,
            logDir: paths.logDir,
            prebuiltDataDir: shared.appendingPathComponent("build"),
            distributionVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        )
    }

    // MARK: - Lifecycle

    func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: paths.userDataDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: paths.logDir, withIntermediateDirectories: true)

        let engine = RimeEngine.shared
        engine.notificationHandler = { [weak self] in self?.handle($0) }
        // Never block startup on the lock: if a CLI deploy is running, just load what
        // is already built and skip our own maintenance pass.
        deployLock = WorkspaceLock.acquire(paths)
        if deployLock != nil { importExistingRimeConfigOnFirstRun() }
        // nil when nothing was prepared (lock held elsewhere, or a broken layer).
        var dirty: [String]?
        if deployLock != nil {
            do {
                dirty = try ConfigLayers(paths: paths).prepareForDeploy(extraTargets: shippedTargets())
            } catch {
                logger.error("config layers invalid, keeping previous build: \(String(describing: error), privacy: .public)")
            }
        }
        engine.initialize(traits)
        generation += 1
        // The frontend config is not part of librime's workspace update; build it here.
        guard deployLock != nil else {
            followPrimarySchema()
            reloadFrontend()
            observeReloadRequests()
            startUsageStats()
            return scheduleVocabularyUpdates()
        }
        frontendDeployed = engine.deployConfigFile("aime.yaml")
        reloadFrontend()
        // Deploys only what changed since the last run (first run builds everything).
        // Pending targets had their build output removed, so check fully: librime's
        // timestamp check alone would skip a target whose sources did not change.
        awaitingDeployAck = dirty != nil
        if !engine.startMaintenance(fullCheck: dirty?.isEmpty == false) {
            if dirty?.isEmpty == true { ConfigLayers(paths: paths).markDeployed() }
            awaitingDeployAck = false
            deployLock = nil
            finishImport(deployed: true)
        }
        observeReloadRequests()
        scheduleVocabularyUpdates()
        startUsageStats()
    }

    // MARK: - Usage statistics

    private var usageTimer: Timer?

    private func startUsageStats() {
        guard usageTimer == nil else { return }
        reloadFeatures()
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: AIMEFeatures.changedNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { InputEngine.shared.reloadFeatures() }
        }
        center.addObserver(forName: UsageStatsStore.clearedNotification, object: nil, queue: .main) { _ in
            // `clear()` returns its write task; discard it so the closure stays Void
            // (Xcode 26 rejects the inferred Task return type).
            MainActor.assumeIsolated { _ = InputEngine.shared.usage.clear() }
        }
        // Buffered counts are written every 5 minutes and when the user leaves a text field.
        let timer = Timer(timeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated { _ = InputEngine.shared.usage.flush() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        usageTimer = timer
        Task.detached(priority: .background) { UsageStatsStore().prune() }
    }

    private func reloadFeatures() {
        let wasTraditional = features.traditional, wasAsciiPunct = features.asciiPunct
        features = AIMEFeatures.load(paths)
        if features.traditional != wasTraditional { activeController?.applyScriptOption() }
        if features.asciiPunct != wasAsciiPunct, asciiPunct != nil {
            asciiPunct = features.asciiPunct
            activeController?.applyPunctOption()
        }
        usage.isEnabled = features.usageStats
        if !features.aiPolish { activeController?.cancelPolish() }
    }

    // MARK: - Subscribed vocabularies

    private var vocabularyTimer: Timer?
    private var vocabularyChecking = false
    /// Set when new vocabulary is ready but the user has not been idle yet.
    private var vocabularyRedeployPending = false
    private var vocabularyWaiting = false

    /// Hourly check (plus one shortly after launch); each feed is fetched at most every
    /// 12 h, the app's release manifest at most daily. Only those public URLs go over
    /// the network — never anything typed.
    private func scheduleVocabularyUpdates() {
        guard vocabularyTimer == nil else { return }
        let timer = Timer(timeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated {
                InputEngine.shared.checkVocabularies()
                InputEngine.shared.checkForAppUpdate()
            }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        vocabularyTimer = timer
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(90))
            InputEngine.shared.checkVocabularies()
            InputEngine.shared.checkForAppUpdate()
        }
    }

    func checkVocabularies() {
        if vocabularyRedeployPending { redeployWhenIdle() }
        let manager = SubscriptionManager(paths: paths)
        guard !vocabularyChecking, !manager.subscriptions().isEmpty else { return }
        vocabularyChecking = true
        Task.detached(priority: .utility) {
            let changed = await manager.updateDue()
            // Build the tables here, off the main thread; the deploy then finds them current.
            if changed { _ = try? manager.ensureTables() }
            await MainActor.run {
                let engine = InputEngine.shared
                engine.vocabularyChecking = false
                if changed {
                    engine.vocabularyRedeployPending = true
                    engine.redeployWhenIdle()
                }
            }
        }
    }

    /// Redeploys once the user has stopped typing for a while, so a background update
    /// never interrupts a composition.
    private func redeployWhenIdle(attempt: Int = 0) {
        guard vocabularyRedeployPending else { return }
        let idle = Date().timeIntervalSince(lastUserKeyAt) > 30
            && activeController?.isComposing != true && activeController?.polish == nil
        if idle, deployLock == nil {
            logger.info("vocabulary changed, redeploying")
            vocabularyRedeployPending = false
            vocabularyWaiting = false
            return redeploy(incremental: true)
        }
        // One waiting chain at a time; after an hour the hourly check picks it up again.
        guard attempt == 0 ? !vocabularyWaiting : true, attempt < 120 else { vocabularyWaiting = false; return }
        vocabularyWaiting = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            InputEngine.shared.redeployWhenIdle(attempt: attempt + 1)
        }
    }

    var firstRunMarker: URL { paths.aimeDir.appendingPathComponent(".initialized") }

    /// First launch on a Mac that already uses RIME (Squirrel): import its configuration
    /// read-only so AIME types like the user's existing setup out of the box. Learned
    /// word frequencies are merged by a sync right after the first deploy.
    private func importExistingRimeConfigOnFirstRun() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: firstRunMarker.path) else { return }
        defer {
            try? fm.createDirectory(at: paths.aimeDir, withIntermediateDirectories: true)
            fm.createFile(atPath: firstRunMarker.path, contents: Data(ISO8601DateFormatter().string(from: Date()).utf8))
        }
        let source = AIMEPaths.squirrelUserDir
        // Only when the AIME workspace is still empty and a RIME setup exists.
        let existing = (try? fm.contentsOfDirectory(atPath: paths.userDataDir.path)) ?? []
        guard fm.fileExists(atPath: source.appendingPathComponent("default.yaml").path)
                || fm.fileExists(atPath: source.appendingPathComponent("default.custom.yaml").path),
              existing.allSatisfy({ ["aime", "build", "installation.yaml", "user.yaml", ".DS_Store"].contains($0) })
        else { return }
        do {
            let importer = SquirrelImporter(paths: paths, source: source)
            let report = try importer.execute(importer.plan())
            // Rides the startup deploy that follows (see `start`).
            if !report.snapshots.isEmpty { runningImport = ImportJob(snapshots: report.snapshots) }
            logger.info("imported existing RIME config: \(report.copied.count, privacy: .public) entries")
        } catch {
            logger.error("first-run import failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func observeReloadRequests() {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.reloadNotification, object: nil, queue: .main
        ) { note in
            let request = note.userInfo?["request"] as? String
            let mode = note.userInfo?["mode"] as? String
            MainActor.assumeIsolated {
                // Sync runs here because this process holds the user dictionaries open;
                // a second process cannot export them (LevelDB lock).
                if mode == "sync" { return InputEngine.shared.syncUserData(request: request) }
                if mode == "import" { return InputEngine.shared.deployImported(request: request) }
                InputEngine.shared.redeploy(request: request, incremental: mode == "auto")
            }
        }
    }

    /// Settings imported a RIME directory with the CLI (`--no-deploy`). The snapshots are
    /// merged here after the deploy, because this process holds the user dictionaries open.
    func deployImported(request: String?) {
        let snapshots = SquirrelImporter.Report.load(paths)?.snapshots ?? []
        queuedRequests.append(QueuedDeploy(request: request, incremental: false, importedSnapshots: snapshots))
        drainDeployQueue()
    }

    /// Equivalent of Squirrel's 重新部署: rebuild everything and restart sessions.
    /// Text being composed is committed first so nothing the user typed is lost.
    ///
    /// `incremental` (automatic deploys after a settings change): appearance-only changes
    /// just reload the frontend config without touching sessions.
    func redeploy(request: String? = nil, incremental: Bool = false) {
        logger.info("redeploy requested")
        // Never reject: rapid settings changes queue up and run as one deploy after
        // the current one (each request still gets its own answer).
        queuedRequests.append(QueuedDeploy(request: request, incremental: incremental))
        drainDeployQueue()
    }

    private func drainDeployQueue(attempt: Int = 0) {
        guard deployLock == nil, !queuedRequests.isEmpty else { return }
        guard let lock = WorkspaceLock.acquire(paths) else {
            // Held by another process (CLI dry run / sync): retry for up to ~15 s.
            guard attempt < 50 else {
                let batch = queuedRequests
                queuedRequests.removeAll()
                for item in batch where item.importedSnapshots == nil { postResult(ok: false, request: item.request, message: "工作区被其他进程占用") }
                if let job = Self.importJob(batch) { failImport(job, message: "工作区被其他进程占用，词频快照未合并") }
                return
            }
            lockRetryTask?.cancel()
            lockRetryTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                InputEngine.shared.drainDeployQueue(attempt: attempt + 1)
            }
            return
        }
        let batch = queuedRequests
        queuedRequests.removeAll()
        let job = Self.importJob(batch)
        runningImport = job
        runDeploy(requests: batch.filter { $0.importedSnapshots == nil }.map(\.request),
                  incremental: job == nil && batch.allSatisfy(\.incremental), lock: lock)
    }

    private static func importJob(_ batch: [QueuedDeploy]) -> ImportJob? {
        let imports = batch.filter { $0.importedSnapshots != nil }
        guard !imports.isEmpty else { return nil }
        // Repeated imports copy into the same sync folders: merge each snapshot once.
        var snapshots: [String] = []
        for name in imports.flatMap({ $0.importedSnapshots ?? [] }) where !snapshots.contains(name) { snapshots.append(name) }
        return ImportJob(requests: imports.map(\.request), snapshots: snapshots)
    }

    private func failImport(_ job: ImportJob, message: String) {
        if !job.snapshots.isEmpty {
            SquirrelImporter.Report.appendWarning(SquirrelImporter.Report.mergeFailed(job.snapshots.count), paths: paths)
        }
        for request in job.requests { postResult(ok: false, request: request, message: message) }
    }

    /// Called once the running deploy has released the workspace, before anything queued
    /// starts: the merge must follow this deploy, not lose the lock to the next one.
    private func finishImport(deployed: Bool) {
        guard let job = runningImport else { return }
        runningImport = nil
        guard deployed else { return failImport(job, message: "部署失败，词频快照未合并，详见日志") }
        guard !job.snapshots.isEmpty else {
            for request in job.requests { postResult(ok: true, request: request, message: nil) }
            return
        }
        // Learned frequencies do not depend on the appearance config: merge either way.
        let frontendFailed = !frontendDeployed
        syncUserData(requests: frontendFailed ? [] : job.requests, importedSnapshots: job.snapshots)
        if frontendFailed {
            for request in job.requests { postResult(ok: false, request: request, message: "配置已导入，但外观配置编译失败，详见日志") }
        }
    }

    private func runDeploy(requests: [String?], incremental: Bool, lock: WorkspaceLock) {
        func answer(ok: Bool, message: String?) {
            for request in requests { postResult(ok: ok, request: request, message: message) }
        }
        func progress(_ stage: String, _ total: Int) {
            for request in requests { postProgress(request: request, stage: stage, total: total) }
        }
        let layers = ConfigLayers(paths: paths)
        let dirty: [String]
        do {
            dirty = try layers.prepareForDeploy(extraTargets: shippedTargets())
        } catch {
            // Broken layer: keep the running engine and previous build untouched.
            answer(ok: false, message: String(describing: error))
            if let job = runningImport {
                runningImport = nil
                failImport(job, message: String(describing: error))
            }
            return drainDeployQueue()
        }
        if incremental, dirty.allSatisfy({ $0 == "aime" }) {
            // Appearance / app options only: no librime maintenance, sessions untouched.
            progress("frontend", 0)
            let ok = dirty.isEmpty || RimeEngine.shared.deployConfigFile("aime.yaml")
            if ok { frontendDeployed = true; layers.markDeployed() }
            reloadFrontend()
            withExtendedLifetime(lock) {}
            answer(ok: ok, message: ok ? nil : "外观配置编译失败，详见日志")
            return drainDeployQueue()
        }
        progress("schemas", dirty.filter { $0 != "aime" }.count)
        deployLock = lock
        awaitingDeployAck = true
        pendingRequests = requests
        activeController?.cancelPolish()
        activeController?.flushBeforeEngineRestart()
        panel.hide()
        let engine = RimeEngine.shared
        engine.cleanupAllSessions()
        engine.initialize(traits)
        generation += 1
        frontendDeployed = engine.deployConfigFile("aime.yaml")
        reloadFrontend()
        // Always a full check: a non-full pass misses targets whose build output was
        // removed by prepareForDeploy (and takes about as long, ~0.3 s).
        if !engine.startMaintenance(fullCheck: true) {
            // Nothing to rebuild; report the frontend result once this call stack (which
            // still holds `lock`) has unwound, so an import's merge can take the workspace.
            Task { @MainActor in InputEngine.shared.finishDeploy(ok: InputEngine.shared.frontendDeployed, schemasDeployed: true) }
        }
    }

    /// `request` (from Settings) gets its own answer through `finishDeploy`, which
    /// librime's deploy success/failure notification triggers when the sync ends.
    func syncUserData(request: String? = nil) {
        syncUserData(requests: request.map { [$0] } ?? [], importedSnapshots: [])
    }

    private func syncUserData(requests: [String?], importedSnapshots: [String]) {
        guard deployLock == nil, let lock = WorkspaceLock.acquire(paths) else {
            showStatus("另一个部署正在进行")
            if !importedSnapshots.isEmpty {
                SquirrelImporter.Report.appendWarning(SquirrelImporter.Report.mergeFailed(importedSnapshots.count), paths: paths)
            }
            let message = importedSnapshots.isEmpty ? "另一个部署正在进行，请稍后再同步" : "另一个部署正在进行，词频快照未合并，可稍后重新导入"
            for request in requests { postResult(ok: false, request: request, message: message) }
            return
        }
        deployLock = lock
        syncInProgress = true
        pendingRequests.append(contentsOf: requests)
        activeController?.flushBeforeEngineRestart()
        RimeEngine.shared.cleanupAllSessions()
        generation += 1
        if !importedSnapshots.isEmpty {
            // The deploy that preceded this may still be winding down its maintenance thread.
            RimeEngine.shared.joinMaintenance()
            let restorable = importedSnapshots.prefix(256)
            let failed = restorable.filter {
                !RimeEngine.shared.restoreUserDictionary(from: paths.userDataDir.appendingPathComponent("sync/\($0)"))
            }.count + importedSnapshots.count - restorable.count
            if failed > 0 { SquirrelImporter.Report.appendWarning(SquirrelImporter.Report.mergeFailed(failed), paths: paths) }
        }
        if !RimeEngine.shared.syncUserData() {
            if !importedSnapshots.isEmpty {
                SquirrelImporter.Report.appendWarning(SquirrelImporter.Report.mergeFailed(importedSnapshots.count), paths: paths)
            }
            deployLock = nil
            syncInProgress = false
            for request in pendingRequests { postResult(ok: false, request: request, message: "同步未能开始，详见日志") }
            pendingRequests = []
        }
    }

    /// The primary schema is the first of the schema list (输入方案 › 已启用). librime
    /// starts new sessions with the schema used last instead, so when the user changes
    /// the primary in Settings, switch to it and make it the remembered one. Later
    /// switches with ⌃` are the user's and stay remembered as usual.
    func followPrimarySchema() {
        guard let primary = RimeEngine.shared.schemaList().first?.id else { return }
        let key = "appliedPrimarySchema"
        guard UserDefaults.standard.string(forKey: key) != primary else { return }
        UserDefaults.standard.set(primary, forKey: key)
        RimeEngine.shared.rememberSelectedSchema(primary)
        if let session = activeController?.session, session.currentSchema != primary { _ = session.selectSchema(primary) }
        logger.info("primary schema is now \(primary, privacy: .public)")
    }

    /// `schemasDeployed`: librime built the schemas, even if the frontend config failed
    /// (`ok` is false then); an import still merges its snapshots in that case.
    private func finishDeploy(ok: Bool, schemasDeployed: Bool? = nil) {
        // Only a deploy that went through prepareForDeploy is acknowledged; a user
        // dictionary sync also ends here and must not clear pending targets.
        if ok, awaitingDeployAck { ConfigLayers(paths: paths).markDeployed() }
        awaitingDeployAck = false
        if ok { followPrimarySchema() }
        let failure = syncInProgress ? "同步失败，详见日志" : "部署失败，详见日志"
        syncInProgress = false
        deployLock = nil
        for request in pendingRequests { postResult(ok: ok, request: request, message: ok ? nil : failure) }
        pendingRequests = []
        finishImport(deployed: schemasDeployed ?? ok)
        drainDeployQueue()
    }

    private func shippedTargets() -> [ConfigTarget] {
        var targets: [ConfigTarget] = [.default, .frontend]
        if let defaults = paths.sharedDataDir?.appendingPathComponent("aime/defaults"),
           let names = try? FileManager.default.contentsOfDirectory(atPath: defaults.path) {
            for name in names where name.hasSuffix(".yaml") {
                let base = String(name.dropLast(5))
                if base != "default", base != "aime" { targets.append(.schema(base)) }
            }
        }
        return targets
    }

    // MARK: - Notifications from librime

    private func handle(_ notification: RimeNotification) {
        switch notification {
        case .deployStarted:
            showStatus(syncInProgress ? "同步中…" : "部署中…")
        case .deploySucceeded:
            reloadFrontend()
            if syncInProgress {
                // A sync does not rebuild the frontend; its own result is what counts.
                showStatus("同步完成")
                finishDeploy(ok: true)
            } else {
                showStatus(frontendDeployed ? "部署完成" : "外观配置部署失败")
                finishDeploy(ok: frontendDeployed, schemasDeployed: true)
            }
        case .deployFailed:
            showStatus(syncInProgress ? "同步失败" : "部署失败")
            finishDeploy(ok: false)
        case let .optionChanged(name, enabled):
            guard Date().timeIntervalSince(lastUserKeyAt) < 0.6,
                  ["ascii_mode", "full_shape", "traditionalization", "ascii_punct", "emoji"].contains(name),
                  let session = activeController?.session else { return }
            let label = session.stateLabel(option: name, state: enabled, abbreviated: false)
            if !label.isEmpty, activeController?.isComposing == false { showStatus(label) }
        case let .schemaChanged(_, name):
            if !name.isEmpty { showStatus(name) }
        default:
            break
        }
    }

    /// Result notifications echo the request id so the settings app can match them.
    /// Distributed notifications cannot authenticate the sender; they only trigger work
    /// the user could trigger anyway (a redeploy) and carry no data back into AIME.
    private func postProgress(request: String?, stage: String, total: Int) {
        var info: [String: Any] = ["stage": stage, "total": total]
        if let request { info["request"] = request }
        DistributedNotificationCenter.default().postNotificationName(
            Self.progressNotification, object: nil, userInfo: info, deliverImmediately: true
        )
    }

    private func postResult(ok: Bool, request: String?, message: String?) {
        var info: [String: Any] = ["ok": ok, "log": paths.logDir.path]
        if let request { info["request"] = request }
        if let message { info["message"] = message }
        DistributedNotificationCenter.default().postNotificationName(
            Self.resultNotification, object: nil, userInfo: info, deliverImmediately: true
        )
    }

    // MARK: - Theme & app options

    func reloadFrontend() {
        guard let loaded = try? ConfigValue.load(contentsOf: paths.builtConfig("aime")) else {
            logger.error("frontend config unavailable or invalid; keeping previous configuration")
            return
        }
        frontend = loaded
        asciiState.scope = frontend.value(at: "ascii_state/scope")?.stringValue.flatMap(AsciiStateScope.init(rawValue:)) ?? .global
        refreshTheme(force: true)
    }

    func refreshTheme(force: Bool = false) {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard force || dark != isDark else { return }
        isDark = dark
        panel.theme = PanelTheme(frontend: frontend, dark: dark)
    }

    struct AppOptions {
        /// Configured initial state: true = English, false = Chinese, nil = shared state.
        var asciiMode: Bool?
        /// Punctuation pinned for this app: true = English, nil = the shared state.
        var asciiPunct: Bool?
        var inline: Bool?
        var vimMode = false
    }

    func appOptions(for bundleID: String?) -> AppOptions {
        guard let bundleID, let options = frontend["app_options"]?[bundleID] else { return AppOptions() }
        var result = AppOptions()
        result.asciiMode = options["ascii_mode"]?.boolValue
        result.asciiPunct = options["ascii_punct"]?.boolValue
        if options["no_inline"]?.boolValue == true { result.inline = false }
        if options["inline"]?.boolValue == true { result.inline = true }
        result.vimMode = options["vim_mode"]?.boolValue ?? false
        return result
    }

    // MARK: - Status bubble

    func showStatus(_ text: String) {
        statusHideTask?.cancel()
        panel.show(PanelState(status: text), at: activeController?.cursorRect() ?? .zero)
        statusHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self else { return }
            if let controller = self.activeController { controller.restorePanelAfterStatus() } else { self.panel.hide() }
        }
    }

    func cancelStatus() { statusHideTask?.cancel() }

    private var deployNoticeGeneration = -1

    /// Shows "部署中…" at most once per engine generation when keys arrive mid-deploy.
    func noteKeyDuringDeploy() {
        guard deployNoticeGeneration != generation else { return }
        deployNoticeGeneration = generation
        showStatus("部署中，稍候即可输入中文…")
    }
}
