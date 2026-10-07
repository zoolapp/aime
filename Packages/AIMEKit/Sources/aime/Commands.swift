import AIMECore
import Carbon
import ArgumentParser
import Foundation
import RimeKit

struct Deploy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Compile the workspace (like Squirrel's 重新部署).")

    @OptionGroup var workspace: WorkspaceOptions

    @Flag(help: "Validate pending changes in a throwaway copy; the real workspace is untouched.")
    var dryRun = false

    @MainActor
    func run() async throws {
        let lock = dryRun ? nil : try Workspace.lock(workspace.paths)
        defer { _ = lock }
        let result = dryRun
            ? try Workspace.dryRun(options: workspace)
            : try Workspace.deploy(traits: workspace.traits(), paths: workspace.paths)
        let verb = dryRun ? "dry-run" : "deploy"
        print("\(verb): \(result.succeeded ? "ok" : "FAILED") in \(String(format: "%.2f", result.duration))s")
        print("schemas: \(result.schemas.joined(separator: ", "))")
        if !result.missing.isEmpty {
            printErr("schemas that failed to build: \(result.missing.joined(separator: ", "))")
            printErr("see librime logs in \(workspace.paths.logDir.path)")
        }
        if !result.succeeded { throw ExitCode.failure }
        if !dryRun { DistributedNotificationCenter.default().postNotificationName(.init("app.zool.aime.reload"), object: nil) }
    }
}

struct Bench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Measure per-keystroke latency (process_key + get_context).")

    @OptionGroup var workspace: WorkspaceOptions

    @Option(help: "Schema to benchmark.") var schema = "rime_ice"
    @Option(help: "Keys to type per iteration.") var keys = "nihaoshijie"
    @Option(help: "Number of iterations.") var iterations = 1000
    @Option(help: "Fail when p99 latency exceeds this many milliseconds.") var assertP99Ms: Double?
    @Flag(help: "Print the first page of candidates after typing the keys once.") var printCandidates = false
    @Flag(help: "Skip the deploy step (workspace must already be deployed).") var noDeploy = false

    @MainActor
    func run() async throws {
        let traits = try workspace.traits()
        let lock = try Workspace.lock(workspace.paths)
        defer { _ = lock }
        if !noDeploy {
            let result = try Workspace.deploy(traits: traits, paths: workspace.paths)
            guard result.succeeded else { throw ValidationError("deploy failed; run `aime deploy` for details") }
        } else {
            RimeEngine.shared.initialize(traits)
        }
        let engine = RimeEngine.shared
        let session = try engine.createSession()
        guard session.selectSchema(schema) else { throw ValidationError("schema '\(schema)' is not available") }

        let scalars = Array(keys.unicodeScalars)
        // Warm-up: first lookups page in dictionaries.
        for _ in 0..<5 { for key in scalars { session.processKey(RimeKey.keysym(forCharacter: key)) }; session.clearComposition() }

        if printCandidates {
            for key in scalars {
                session.processKey(RimeKey.keysym(forCharacter: key))
            }
            let context = session.context()
            for (index, candidate) in context.candidates.enumerated() {
                print("\(context.labels[safe: index] ?? "\(index + 1)"). \(candidate.text)\(candidate.comment.isEmpty ? "" : "  \(candidate.comment)")")
            }
            session.clearComposition()
        }

        var samples: [Double] = []
        samples.reserveCapacity(iterations * scalars.count)
        let clock = ContinuousClock()
        for _ in 0..<iterations {
            for key in scalars {
                let elapsed = clock.measure {
                    session.processKey(RimeKey.keysym(forCharacter: key))
                    _ = session.context()
                }
                samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
            }
            session.clearComposition()
        }
        samples.sort()
        func percentile(_ p: Double) -> Double { samples[min(samples.count - 1, Int(Double(samples.count) * p))] }
        let p50 = percentile(0.5), p90 = percentile(0.9), p99 = percentile(0.99), maximum = samples.last ?? 0
        print(String(format: "schema=%@ keys=%@ samples=%d  p50=%.3fms  p90=%.3fms  p99=%.3fms  max=%.3fms",
                     schema, keys, samples.count, p50, p90, p99, maximum))
        if let limit = assertP99Ms, p99 > limit {
            printErr(String(format: "p99 %.3fms exceeds limit %.3fms", p99, limit))
            throw ExitCode.failure
        }
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check installation, directories and plugins.")

    @OptionGroup var workspace: WorkspaceOptions

    @MainActor
    func run() async throws {
        let paths = workspace.paths
        let fm = FileManager.default
        print("aime \(AIMECommand.configuration.version) · librime \(RimeEngine.shared.version)")
        print("user dir: \(paths.userDataDir.path)\(fm.fileExists(atPath: paths.userDataDir.path) ? "" : " (missing)")")
        if let shared = try? workspace.sharedDataDir() {
            print("shared dir: \(shared.path)")
        } else {
            print("shared dir: NOT FOUND")
        }
        print("input source: \(InputSourceRegistrar.status())")

        let plugins = PluginLocator.plugins()
        print("plugins: \(plugins.isEmpty ? "none found" : plugins.joined(separator: " "))")

        let store = SettingsStore(paths: paths)
        let schemas = store.enabledSchemas()
        print("deployed schemas: \(schemas.isEmpty ? "none (run `aime deploy`)" : schemas.joined(separator: ", "))")
        let layers = ConfigLayers(paths: paths)
        print("managed configs: \(layers.managedTargets().map(\.configID).joined(separator: ", "))")
        let packages = PackageManager(paths: paths).installedPackages()
        print("packages: \(packages.isEmpty ? "none" : packages.map { "\($0.id)@\($0.version)" }.joined(separator: ", "))")
        if fm.fileExists(atPath: AIMEPaths.squirrelUserDir.path) {
            print("squirrel config: \(AIMEPaths.squirrelUserDir.path) (importable with `aime import-squirrel`)")
        }
    }
}

struct ImportSquirrel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-squirrel",
        abstract: "Import an existing Rime directory (read-only) into the AIME workspace."
    )

    @OptionGroup var workspace: WorkspaceOptions
    @Option(help: "Source Rime directory.") var from = AIMEPaths.squirrelUserDir.path
    @Flag(help: "Only print the plan.") var dryRun = false
    @Flag(help: "Skip deploying after the import.") var noDeploy = false

    @MainActor
    func run() async throws {
        let lock = dryRun ? nil : try Workspace.lock(workspace.paths)
        defer { _ = lock }
        let importer = SquirrelImporter(paths: workspace.paths, source: URL(fileURLWithPath: (from as NSString).expandingTildeInPath))
        let plan = try importer.plan()
        for action in plan.actions {
            switch action {
            case let .copy(path): print("copy      \(path)")
            case let .importCustom(path, target): print("layer     \(path) → aime/imported/\(target.customName).custom.yaml")
            case let .importSnapshots(path): print("snapshots \(path)/*/*.userdb.txt → sync/ (merged on sync)")
            case let .skip(path, reason): print("skip      \(path) — \(reason)")
            }
        }
        if dryRun { return }
        let report = try importer.execute(plan)
        print("imported \(report.copied.count) entries, \(report.customLayers.count) custom layers, \(report.snapshots.count) snapshots")
        for warning in report.warnings { printErr("warning: \(warning)") }
        if !report.colorSchemesCarriedOver.isEmpty {
            print("carried over color schemes: \(report.colorSchemesCarriedOver.joined(separator: ", "))")
        }
        if noDeploy { return }
        let result = try Workspace.deploy(traits: workspace.traits(), paths: workspace.paths)
        print("deploy: \(result.succeeded ? "ok" : "FAILED") (\(result.schemas.joined(separator: ", ")))")
        if !report.snapshots.isEmpty {
            print("merging user dictionaries: \(RimeEngine.shared.syncUserData() ? "started" : "failed")")
            RimeEngine.shared.joinMaintenance()
        }
        if !result.succeeded { throw ExitCode.failure }
    }
}

struct Package: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage dictionary and schema packages from the registry.",
        subcommands: [List.self, Install.self, Uninstall.self]
    )

    struct List: AsyncParsableCommand {
        @OptionGroup var workspace: WorkspaceOptions
        func run() async throws {
            let manager = PackageManager(paths: workspace.paths)
            for package in manager.registry.packages {
                let installed = manager.installed(package.id)
                let mark = installed.map { "installed \($0.version)" } ?? "-"
                print("\(package.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(package.version.padding(toLength: 12, withPad: " ", startingAt: 0)) \(mark.padding(toLength: 22, withPad: " ", startingAt: 0)) \(package.title) · \(package.license)")
            }
        }
    }

    struct Install: AsyncParsableCommand {
        @OptionGroup var workspace: WorkspaceOptions
        @Argument(help: "Package id from `aime package list`.") var id: String
        @Option(help: "Install from a local file instead of downloading (still sha256-verified).") var fromFile: String?

        func run() async throws {
            let lock = try Workspace.lock(workspace.paths)
            defer { _ = lock }
            let manager = PackageManager(paths: workspace.paths)
            let record: InstalledPackage
            if let fromFile {
                guard let package = manager.registry.package(id) else { throw PackageError.unknownPackage(id) }
                record = try manager.install(package, archive: URL(fileURLWithPath: fromFile)) { print($0) }
            } else {
                record = try await manager.install(id) { print($0) }
            }
            print("installed \(record.id)@\(record.version): \(record.files.count) files")
            if let backup = record.backupDir { print("backed up overwritten files to \(backup)") }
            print("run `aime deploy` to apply")
        }
    }

    struct Uninstall: AsyncParsableCommand {
        @OptionGroup var workspace: WorkspaceOptions
        @Argument var id: String
        func run() async throws {
            let lock = try Workspace.lock(workspace.paths)
            defer { _ = lock }
            let manager = PackageManager(paths: workspace.paths)
            if manager.installed(id) != nil, let package = manager.registry.package(id),
               package.kind == .model, let filename = package.source.filename, filename.hasSuffix(".gram") {
                try SettingsStore(paths: workspace.paths).disableLanguageModelReferences(named: String(filename.dropLast(5)))
                print("disabled model references; run `aime deploy` to apply")
            }
            let result = try manager.uninstall(id)
            print("removed \(result.removed.count) files")
            if !result.kept.isEmpty { print("kept \(result.kept.count) modified files: \(result.kept.joined(separator: ", "))") }
        }
    }
}

struct Get: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the effective value of a catalog setting (or all).")
    @OptionGroup var workspace: WorkspaceOptions
    @Argument(help: "Setting id, e.g. menu.page_size. Omit to list all.") var id: String?

    func run() async throws {
        let store = SettingsStore(paths: workspace.paths)
        let settings = id.map { id in store.catalog.settings.filter { $0.id == id } } ?? store.catalog.settings
        if settings.isEmpty { throw ValidationError("unknown setting '\(id ?? "")'") }
        for setting in settings {
            let value = store.value(for: setting).map(describe) ?? "—"
            print("\(setting.id) = \(value)\(store.isCustomized(setting) ? "  (customized)" : "")")
        }
    }

    func describe(_ value: ConfigValue) -> String {
        switch value {
        case let .list(items): "[" + items.map(describe).joined(separator: ", ") + "]"
        case .map: (try? value.yamlString().replacingOccurrences(of: "\n", with: " ")) ?? "{…}"
        default: value.stringValue ?? "null"
        }
    }
}

struct Set: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Change a catalog setting in the generated layer.")
    @OptionGroup var workspace: WorkspaceOptions
    @Argument var id: String
    @Argument(help: "New value (YAML scalar/list), or `--reset`.") var value: String?
    @Flag var reset = false
    @Flag(help: "Deploy after writing.") var deploy = false

    @MainActor
    func run() async throws {
        let store = SettingsStore(paths: workspace.paths)
        guard let setting = store.catalog.setting(id) else { throw ValidationError("unknown setting '\(id)'") }
        if reset {
            try store.reset(setting)
        } else {
            guard let value else { throw ValidationError("missing value") }
            try store.set(try ConfigValue.parse(yaml: value), for: setting)
        }
        print("\(id) → \(reset ? "reset" : value ?? "")")
        if deploy {
            let lock = try Workspace.lock(workspace.paths)
            defer { _ = lock }
            let result = try Workspace.deploy(traits: workspace.traits(), paths: workspace.paths)
            print("deploy: \(result.succeeded ? "ok" : "FAILED")")
            if !result.succeeded { throw ExitCode.failure }
        }
    }
}

struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Sync user dictionaries with the sync directory (installation.yaml sync_dir).")
    @OptionGroup var workspace: WorkspaceOptions

    @MainActor
    func run() async throws {
        let lock = try Workspace.lock(workspace.paths)
        defer { _ = lock }
        let engine = RimeEngine.shared
        // librime logs per-dictionary failures but still finishes the task; the only
        // signal is the deploy failure notification (e.g. the input method holds a userdb).
        var failed = false
        engine.notificationHandler = { if case .deployFailed = $0 { failed = true } }
        engine.initialize(try workspace.traits())
        guard engine.syncUserData() else { throw ValidationError("sync could not start") }
        engine.joinMaintenance()
        try? await Task.sleep(for: .milliseconds(50)) // let queued main-queue notifications run
        if failed { throw ValidationError("sync failed; user dictionaries in use or unreadable (see the librime log)") }
        print("synced with \(engine.userDataSyncDir)")
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct Register: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Register (and optionally enable) AIME as a macOS input source.")
    @Option(help: "Path to AIME.app.") var app = AIMEIdentity.installedApp.path
    @Flag(help: "Also enable the input source.") var enable = false

    func run() async throws {
        let status = InputSourceRegistrar.register(appURL: URL(fileURLWithPath: app))
        print("register \(app): \(status == noErr ? "ok" : "error \(status)")")
        if enable { print("enable: \(InputSourceRegistrar.enable() ? "ok" : "not yet listed — log out and back in, then retry")") }
        print("input source: \(InputSourceRegistrar.status())")
    }
}


struct Subscribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Online vocabularies (Rime dict.yaml / table / word list URLs).",
        subcommands: [List.self, Add.self, Update.self, Remove.self]
    )

    static func rebuild(_ workspace: WorkspaceOptions) throws -> Int {
        let store = SettingsStore(paths: workspace.paths)
        return try SubscriptionManager(paths: workspace.paths).rebuild(schemas: store.pendingSchemas())
    }

    struct List: AsyncParsableCommand {
        @OptionGroup var workspace: WorkspaceOptions
        func run() async throws {
            let formatter = ISO8601DateFormatter()
            for item in SubscriptionManager(paths: workspace.paths).subscriptions() {
                let updated = item.remoteUpdated.map { formatter.string(from: $0) } ?? "—"
                print("\(item.id)  \(item.entryCount) 词  +\(item.newEntries)  更新于 \(updated)  \(item.url.absoluteString)\(item.lastError.map { "  ⚠️ \($0)" } ?? "")")
            }
        }
    }

    struct Add: AsyncParsableCommand {
        @OptionGroup var workspace: WorkspaceOptions
        @Argument var url: String
        @Option var name: String?
        func run() async throws {
            let item = try await SubscriptionManager(paths: workspace.paths).add(url: url, name: name)
            if let error = item.lastError { throw ValidationError(error) }
            print("subscribed \(item.id): \(item.entryCount) entries; tables rebuilt with \(try Subscribe.rebuild(workspace)) entries")
            print("run `aime deploy` to apply")
        }
    }

    struct Update: AsyncParsableCommand {
        @OptionGroup var workspace: WorkspaceOptions
        @Flag(help: "Check even manual feeds, ignoring each feed's update interval (up to 32 per run).") var force = false
        func run() async throws {
            let manager = SubscriptionManager(paths: workspace.paths)
            let result = await manager.refresh(mode: force ? .manual : .due)
            let checked = Swift.Set(result.checkedIDs)
            for item in manager.subscriptions() where checked.contains(item.id) {
                print("\(item.id): \(item.entryCount) entries, +\(item.newEntries) new")
            }
            for (id, error) in result.errors.sorted(by: { $0.key < $1.key }) {
                print("\(id): ⚠️ \(error)")
            }
            if let error = result.catalogError { print("catalog: ⚠️ \(error)") }
            if result.deferredCount > 0 { print("\(result.deferredCount) feeds deferred to the next run") }
            if result.changed {
                print("tables rebuilt with \(try Subscribe.rebuild(workspace)) entries")
                print("run `aime deploy` to apply")
            } else {
                print("checked \(result.checkedIDs.count) feeds; cached content unchanged")
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        @OptionGroup var workspace: WorkspaceOptions
        @Argument var id: String
        func run() async throws {
            try SubscriptionManager(paths: workspace.paths).remove(id: id)
            print("removed \(id); tables rebuilt with \(try Subscribe.rebuild(workspace)) entries")
        }
    }
}
