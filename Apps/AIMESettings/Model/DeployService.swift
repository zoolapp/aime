import AIMECore
import AppKit

/// Where the installed pieces live.
enum Locations {
    /// The input method bundle: the one we are embedded in, else the installed copy.
    static var inputMethodApp: URL? {
        let embedding = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if embedding.pathExtension == "app",
           FileManager.default.fileExists(atPath: embedding.appendingPathComponent("Contents/Helpers/aime").path) {
            return embedding
        }
        // Per-user dev install first, then the system-wide .pkg location.
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/AIME.app"),
            URL(fileURLWithPath: "/Library/Input Methods/AIME.app"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var cli: URL? { inputMethodApp?.appendingPathComponent("Contents/Helpers/aime") }

    static var sharedSupport: URL? {
        if let app = inputMethodApp { return app.appendingPathComponent("Contents/SharedSupport") }
        // Development: repository build output.
        let env = ProcessInfo.processInfo.environment["AIME_SHARED_DIR"]
        return env.map { URL(fileURLWithPath: $0) }
    }

    static let inputMethodBundleID = "app.zool.inputmethod.aime"
}

/// Deploys through the running input method (so its sessions reload immediately), or
/// through the bundled CLI when the input method is not running.
@MainActor
final class DeployService {
    enum Outcome: Equatable {
        case success
        case failure(String)
    }

    struct CommandResult {
        var ok: Bool
        var output: String
    }

    let paths: AIMEPaths

    init(paths: AIMEPaths) { self.paths = paths }

    var inputMethodIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Locations.inputMethodBundleID).isEmpty
    }

    /// A sandboxed workspace (AIME_USER_DIR, used by UI automation) is never handed to
    /// the running input method, which serves the real one.
    var usesInputMethod: Bool {
        inputMethodIsRunning && ProcessInfo.processInfo.environment["AIME_USER_DIR"] == nil
    }

    func deploy(automatic: Bool = false, progress: @escaping @MainActor (String, Int) -> Void = { _, _ in }) async -> Outcome {
        if usesInputMethod {
            // Never start a second writer on timeout: the input method may still be
            // deploying. Report the unknown outcome instead.
            return await deployViaInputMethod(automatic: automatic, progress: progress)
                ?? .failure("输入法未在 3 分钟内返回部署结果，可能仍在部署；请稍后查看日志 \(paths.logDir.path)")
        }
        let result = await run(["deploy"])
        return result.ok ? .success : .failure(Self.summarize(result.output))
    }

    /// Validates pending changes in a throwaway copy of the workspace.
    func dryRun() async -> CommandResult { await run(["deploy", "--dry-run"]) }

    private func deployViaInputMethod(automatic: Bool, progress: @escaping @MainActor (String, Int) -> Void) async -> Outcome? {
        let center = DistributedNotificationCenter.default()
        let request = UUID().uuidString
        nonisolated(unsafe) let progressToken = center.addObserver(
            forName: Notification.Name("app.zool.aime.deploy.progress"), object: nil, queue: .main
        ) { note in
            guard note.userInfo?["request"] as? String == request else { return }
            let stage = note.userInfo?["stage"] as? String ?? ""
            let total = note.userInfo?["total"] as? Int ?? 0
            MainActor.assumeIsolated { progress(stage, total) }
        }
        defer { center.removeObserver(progressToken) }
        let logDir = paths.logDir.path
        let stream = AsyncStream<Outcome> { continuation in
            nonisolated(unsafe) let token = center.addObserver(forName: Notification.Name("app.zool.aime.deploy.result"), object: nil, queue: .main) { note in
                // Only the answer to this request counts.
                guard note.userInfo?["request"] as? String == request else { return }
                let ok = note.userInfo?["ok"] as? Bool ?? false
                let message = note.userInfo?["message"] as? String ?? "部署失败"
                continuation.yield(ok ? .success : .failure("\(message)（日志：\(logDir)）"))
                continuation.finish()
            }
            continuation.onTermination = { _ in center.removeObserver(token) }
        }
        center.postNotificationName(Notification.Name("app.zool.aime.reload"), object: nil,
                                    userInfo: ["request": request, "mode": automatic ? "auto" : "full"], deliverImmediately: true)
        return await withTaskGroup(of: Outcome?.self) { group in
            group.addTask { for await outcome in stream { return outcome }; return nil }
            group.addTask { try? await Task.sleep(for: .seconds(180)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Runs the bundled `aime` CLI off the main thread.
    func run(_ arguments: [String]) async -> CommandResult {
        guard let cli = Locations.cli else {
            return CommandResult(ok: false, output: "未找到 AIME 输入法（~/Library/Input Methods/AIME.app），请先安装。")
        }
        let userDir = paths.userDataDir.path
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments + ["--user-dir", userDir]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return CommandResult(ok: process.terminationStatus == 0, output: String(decoding: data, as: UTF8.self))
            } catch {
                return CommandResult(ok: false, output: String(describing: error))
            }
        }.value
    }

    static func summarize(_ output: String) -> String {
        let lines = output.split(separator: "\n").filter { !$0.hasPrefix("I20") && !$0.hasPrefix("W20") && !$0.contains("Logging before") }
        return lines.suffix(4).joined(separator: "\n")
    }
}
