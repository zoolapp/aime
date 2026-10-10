import AIMECore
import ArgumentParser
import Foundation
import RimeKit

@main
struct AIMECommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aime",
        abstract: "AIME command line — deploy, benchmark and manage your Rime workspace.",
        version: "0.1.8",
        subcommands: [
            Deploy.self, Bench.self, Doctor.self, ImportSquirrel.self, Package.self,
            Get.self, Set.self, Sync.self, Register.self, Subscribe.self, DiagnosticsCommand.self,
        ]
    )
}

/// Options shared by every command that touches a workspace.
struct WorkspaceOptions: ParsableArguments {
    @Option(help: "AIME user data directory (default: ~/Library/AIME/Rime or $AIME_USER_DIR).")
    var userDir: String?

    @Option(help: "Shared data directory (default: bundled SharedSupport).")
    var sharedDir: String?

    @Flag(help: "Log librime INFO messages to stderr.")
    var verbose = false

    var paths: AIMEPaths {
        var paths = userDir.map {
            AIMEPaths(userDataDir: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true))
        } ?? .standard
        paths.sharedDataDir = try? sharedDataDir()
        return paths
    }

    func sharedDataDir() throws -> URL {
        if let sharedDir { return URL(fileURLWithPath: (sharedDir as NSString).expandingTildeInPath, isDirectory: true) }
        if let located = SharedSupportLocator.locate() { return located }
        throw ValidationError("Cannot find SharedSupport. Run scripts/fetch-dicts.sh or pass --shared-dir.")
    }

    @MainActor
    func traits(stagingDir: URL? = nil) throws -> RimeTraits {
        let logLevel: Int32 = verbose ? 0 : 2
        let paths = self.paths
        try FileManager.default.createDirectory(at: paths.userDataDir, withIntermediateDirectories: true)
        let shared = try sharedDataDir()
        return RimeTraits(
            sharedDataDir: shared,
            userDataDir: paths.userDataDir,
            stagingDir: stagingDir,
            prebuiltDataDir: shared.appendingPathComponent("build"),
            distributionVersion: AIMECommand.configuration.version,
            minLogLevel: logLevel
        )
    }
}

enum SharedSupportLocator {
    /// Inside AIME.app the CLI lives in Contents/MacOS next to Contents/SharedSupport.
    /// During development it walks up to the repository's build/SharedSupport.
    static func locate() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let path = env["AIME_SHARED_DIR"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            for candidate in ["../SharedSupport", "build/SharedSupport"] {
                let url = directory.appendingPathComponent(candidate).standardizedFileURL
                if FileManager.default.fileExists(atPath: url.appendingPathComponent("default.yaml").path) { return url }
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
