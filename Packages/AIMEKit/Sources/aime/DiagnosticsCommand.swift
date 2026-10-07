import AIMECore
import ArgumentParser
import Foundation
import RimeKit

struct DiagnosticsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "diagnostics", abstract: "Export a privacy-filtered diagnostic zip (no input data or credentials).")
    @OptionGroup var workspace: WorkspaceOptions
    @Option(help: "Destination zip file.") var output: String

    @MainActor
    func run() async throws {
        let report = Diagnostics(paths: workspace.paths, librimeVersion: RimeEngine.shared.version)
        try report.export(to: URL(fileURLWithPath: (output as NSString).expandingTildeInPath))
        print("诊断信息已导出。\(Diagnostics.disclosure)")
    }
}
