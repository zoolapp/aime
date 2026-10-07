import Foundation
import Testing
@testable import AIMECore

@Suite struct DiagnosticsTests {
    @Test func exportedZipExcludesPrivateFilesAndRedactsLogs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AIMEPaths(userDataDir: root.appendingPathComponent("Rime"))
        func put(_ relative: String, _ text: String) throws {
            let url = paths.userDataDir.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try put("private.userdb/data", "PRIVATE_USERDB_SENTINEL")
        try put("custom_phrase.txt", "PRIVATE_PHRASE_SENTINEL")
        try put("aime/snippets.json", "PRIVATE_SNIPPET_SENTINEL")
        try put("stats.json", "PRIVATE_STATS_SENTINEL")
        try put("credentials.json", #"{"openai-compatible":"PRIVATE_CREDENTIAL_SENTINEL"}"#)
        try put("aime/generated/default.yaml", "patch:\n  phrase: PRIVATE_YAML_SENTINEL\n")
        try put("aime/imported/default.custom.yaml", "PRIVATE_IMPORTED_SENTINEL")
        try put("user.yaml", "var:\n  previously_selected_schema: rime_ice\nprivate: PRIVATE_USER_YAML_SENTINEL\n")
        try put("aime/features.json", #"{"aiBaseURL":"https://PRIVATE_BASE_SENTINEL.example/v1"}"#)
        try put("aime/update.json", #"{"autoCheck":false,"notes":"PRIVATE_NOTE_SENTINEL","available":{"version":"0.2.0","build":4,"notes":"PRIVATE_REMOTE_SENTINEL"}}"#)
        try put("logs/a.log", (0..<600).map { "line-\($0)" }.joined(separator: "\n") + "\nsk-PRIVATE_LOG_KEY\nBearer PRIVATE_BEARER\nhttps://user:PRIVATE_PASS@example.com/PRIVATE_PATH?key=PRIVATE_QUERY\ninput: PRIVATE_INPUT_SENTINEL\nPRIVATE_CREDENTIAL_SENTINEL\nhttps://PRIVATE_BASE_SENTINEL.example/v1/PRIVATE_SUFFIX?secret=PRIVATE_SUFFIX_QUERY\n")
        try FileManager.default.createSymbolicLink(at: paths.logDir.appendingPathComponent("secret.log"), withDestinationURL: paths.userDataDir.appendingPathComponent("credentials.json"))
        var report = Diagnostics(paths: paths, librimeVersion: "1.17.0", settingsURL: root.appendingPathComponent("Settings.app"))
        report.credentialsURL = paths.userDataDir.appendingPathComponent("credentials.json")
        report.appURLs = [root.appendingPathComponent("user/AIME.app"), root.appendingPathComponent("system/AIME.app")]
        for app in report.appURLs { try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true) }
        let zip = root.appendingPathComponent("diagnostics.zip")
        try report.export(to: zip)
        let unpacked = root.appendingPathComponent("unpacked")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, unpacked.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let files = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
        #expect(Set(files.map(\.lastPathComponent)) == ["system.json", "update.json", "log-0-a.txt"])
        let contents = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(!contents.contains("PRIVATE_"))
        #expect(contents.contains("重复安装"))
        #expect(contents.contains("rime_ice"))
        #expect(contents.contains("example.com/[已脱敏]"))
        #expect(contents.contains("default.custom.yaml"))
        #expect(!contents.contains("line-0\n"))
        #expect(contents.contains("line-599\n"))
        for file in files where file.pathExtension == "json" {
            _ = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        }
        let log = try String(contentsOf: unpacked.appendingPathComponent("log-0-a.txt"), encoding: .utf8)
        #expect(log.hasPrefix("# a\n"))
        #expect(log.split(separator: "\n").count == 501)
    }

    @Test func picksTheNewestLogsOfEachSeverity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var files: [URL] = []
        func put(_ name: String, minutesAgo: Double) throws {
            let url = root.appendingPathComponent(name)
            try name.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -minutesAgo * 60)], ofItemAtPath: url.path)
            files.append(url)
        }
        // Names sort oldest-first in glog; give the alphabetically first INFO file the newest date.
        for day in 10..<35 { try put("rime.aime.x.log.INFO.202609\(day)-000000.1.log", minutesAgo: day == 10 ? 1 : Double(100 - day)) }
        for day in 10..<15 { try put("rime.aime.x.log.WARNING.202609\(day)-000000.1.log", minutesAgo: Double(100 - day)) }
        try put("ime-debug.log", minutesAgo: 5)
        let picked = Diagnostics.recentLogs(files.shuffled())
        #expect(picked.count == 5)
        #expect(picked.map(\.kind) == ["ime-debug", "rime WARNING", "rime WARNING", "rime INFO", "rime INFO"])
        #expect(picked[3].url.lastPathComponent.contains("INFO.20260910"))
        #expect(picked[4].url.lastPathComponent.contains("INFO.20260934"))
        #expect(picked[1].url.lastPathComponent.contains("WARNING.20260914"))
    }

    @Test func findsTheCompanionSettingsForAZipInstallation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("AIME.app")
        let settings = app.appendingPathComponent("Contents/Applications/AIME Settings.app")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        #expect(Diagnostics.locateSettings(current: app.appendingPathComponent("Contents/Helpers"), inputMethodApps: []).path == settings.path)
        #expect(Diagnostics.locateSettings(current: root, inputMethodApps: [app]).path == settings.path)
    }

    @Test func missingWorkspaceIsReadOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AIMEPaths(userDataDir: root.appendingPathComponent("absent"))
        var report = Diagnostics(paths: paths, settingsURL: root.appendingPathComponent("Settings.app"))
        report.credentialsURL = root.appendingPathComponent("absent-credentials.json")
        report.appURLs = [root.appendingPathComponent("AIME.app")]
        try report.export(to: root.appendingPathComponent("report.zip"))
        #expect(!FileManager.default.fileExists(atPath: paths.userDataDir.path))
    }
}
