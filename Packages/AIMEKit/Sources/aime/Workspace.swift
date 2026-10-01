import AIMECore
import ArgumentParser
import Foundation
import RimeKit

/// Deployment orchestration shared by CLI commands.
@MainActor
enum Workspace {
    struct DeployResult {
        var succeeded: Bool
        var schemas: [String]
        var missing: [String]
        var duration: TimeInterval
    }

    /// Installs shims for every target that has shipped AIME defaults, so defaults
    /// apply even before the user customizes anything.
    /// Takes the workspace lock for the lifetime of a command, or fails fast.
    nonisolated static func lock(_ paths: AIMEPaths) throws -> WorkspaceLock {
        guard let lock = WorkspaceLock.acquire(paths) else {
            throw ValidationError("另一个部署/导入正在进行（输入法或其他 aime 进程），请稍后重试。")
        }
        return lock
    }

    static func shippedTargets(shared: URL) -> [ConfigTarget] {
        var targets: [ConfigTarget] = [.default, .frontend]
        let defaults = shared.appendingPathComponent("aime/defaults")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: defaults.path)) ?? [] where name.hasSuffix(".yaml") {
            let base = String(name.dropLast(5))
            if base != "default", base != "aime" { targets.append(.schema(base)) }
        }
        return targets
    }

    /// Deploys and verifies that every schema in `schema_list` produced build output —
    /// librime reports success even when individual schemas fail to compile.
    static func deploy(traits: RimeTraits, paths: AIMEPaths) throws -> DeployResult {
        let start = Date()
        var paths = paths
        paths.sharedDataDir = traits.sharedDataDir
        let layers = ConfigLayers(paths: paths)
        let engine = RimeEngine.shared
        var failed = false
        engine.notificationHandler = { if case .deployFailed = $0 { failed = true } }
        engine.initialize(traits)
        try layers.prepareForDeploy(extraTargets: shippedTargets(shared: traits.sharedDataDir))
        engine.deployAndWait(fullCheck: true)
        let frontendOK = engine.deployConfigFile("aime.yaml")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) // flush queued notifications

        let staging = traits.stagingDir ?? paths.stagingDir
        let built = (try? ConfigValue.load(contentsOf: staging.appendingPathComponent("default.yaml")))
        let schemas = (built?.value(at: "schema_list")?.listValue ?? []).compactMap { $0["schema"]?.stringValue }
        let missing = schemas.filter {
            !FileManager.default.fileExists(atPath: staging.appendingPathComponent("\($0).schema.yaml").path)
        }
        return DeployResult(
            succeeded: !failed && frontendOK && built != nil && missing.isEmpty,
            schemas: schemas, missing: missing, duration: Date().timeIntervalSince(start)
        )
    }

    /// Validates pending changes by deploying a throwaway copy of the user directory.
    /// Nothing in the real user directory (including build/) is modified.
    static func dryRun(options: WorkspaceOptions) throws -> DeployResult {
        let paths = options.paths
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("aime-dry-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: sandbox) }
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: paths.userDataDir.path)) ?? [] {
            if name == "build" || name.hasSuffix(".userdb") || name == "sync" || name.hasPrefix(".") { continue }
            try fm.copyItem(at: paths.userDataDir.appendingPathComponent(name), to: sandbox.appendingPathComponent(name))
        }
        let sandboxPaths = AIMEPaths(userDataDir: sandbox)
        // Mark every managed target dirty so the sandbox rebuilds from scratch.
        let layers = ConfigLayers(paths: sandboxPaths)
        for target in layers.managedTargets() { layers.invalidateBuild(target) }
        var traits = try options.traits()
        traits.userDataDir = sandbox
        return try deploy(traits: traits, paths: sandboxPaths)
    }
}
