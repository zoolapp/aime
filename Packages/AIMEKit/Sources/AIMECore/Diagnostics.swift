public import Foundation
import Darwin

/// An allowlisted snapshot, never an archive of the user's workspace.
public struct Diagnostics: Sendable {
    public let paths: AIMEPaths
    public var librimeVersion: String?
    public var appURLs: [URL]
    public var settingsURL: URL
    public var credentialsURL: URL

    public init(paths: AIMEPaths, librimeVersion: String? = nil,
                settingsURL: URL? = nil) {
        self.paths = paths
        self.librimeVersion = librimeVersion
        let home = FileManager.default.homeDirectoryForCurrentUser
        appURLs = [home.appendingPathComponent("Library/Input Methods/AIME.app"),
                   URL(fileURLWithPath: "/Library/Input Methods/AIME.app")]
        self.settingsURL = settingsURL ?? Self.locateSettings(current: Bundle.main.bundleURL, inputMethodApps: appURLs)
        credentialsURL = ProcessInfo.processInfo.environment["AIME_CREDENTIALS_FILE"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Library/Application Support/AIME/credentials.json")
    }

    static func locateSettings(current: URL, inputMethodApps: [URL]) -> URL {
        if Bundle(url: current)?.bundleIdentifier?.hasPrefix("app.zool.aime.settings") == true { return current }
        // A CLI inside AIME.app should report its companion Settings, including zip installs.
        var ancestor = current
        for _ in 0..<8 {
            if ancestor.lastPathComponent == "AIME.app" {
                let embedded = ancestor.appendingPathComponent("Contents/Applications/AIME Settings.app")
                if FileManager.default.fileExists(atPath: embedded.path) { return embedded }
            }
            ancestor.deleteLastPathComponent()
        }
        let candidates = inputMethodApps.map { $0.appendingPathComponent("Contents/Applications/AIME Settings.app") }
            + [URL(fileURLWithPath: "/Applications/AIME Settings.app")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates.last!
    }

    public static let disclosure = "包含版本、安装状态、配置文件名与大小、更新状态及脱敏日志；不包含输入内容、词频、常用语、统计、配置原文或密钥。"

    public static func filename(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "AIME-diagnostics-\(formatter.string(from: date)).zip"
    }

    /// Creates a zip from fresh, private staging files only. The source is read-only.
    public func export(to destination: URL) throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("aime-diagnostics-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let report = stage.appendingPathComponent("report")
        try fm.createDirectory(at: report, withIntermediateDirectories: false)
        try writeReport(to: report)
        let zip = stage.appendingPathComponent("report.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", report.path, zip.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        // Atomic replacement avoids leaving a half-written export on failure.
        try Data(contentsOf: zip).write(to: destination, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    func writeReport(to directory: URL) throws {
        let fm = FileManager.default
        let credentials = regularData(credentialsURL).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        var secrets = credentials.values.filter { !$0.isEmpty }
        var info: [String: Any] = ["privacy": Self.disclosure,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": Self.architecture,
            "installations": appURLs.enumerated().map { index, url in
                ["location": index == 0 ? "~/Library/Input Methods/AIME.app" : "/Library/Input Methods/AIME.app",
                 "exists": fm.fileExists(atPath: url.path), "bundle": bundleInfo(url)] as [String: Any]
            },
            "installationStatus": appURLs.allSatisfy { fm.fileExists(atPath: $0.path) } ? "重复安装" : "无重复安装",
            "AIME Settings": bundleInfo(settingsURL),
            "apiKey": !secrets.isEmpty ? "已配置" : "未配置",
        ]
        if let data = regularData(paths.aimeDir.appendingPathComponent("features.json")),
           let features = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let baseURL = features["aiBaseURL"] as? String ?? ""
            info["baseURL"] = baseURL.isEmpty ? "未配置" : "已配置"
            if !baseURL.isEmpty { secrets.append(baseURL) }
        } else { info["baseURL"] = "未配置" }
        let shippedVersion = paths.sharedDataDir.flatMap { regularData($0.appendingPathComponent("aime/LIBRIME_VERSION")) }
            .flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        info["librime"] = librimeVersion ?? shippedVersion ?? "未知（未找到构建元数据）"
        // Extract just the persisted schema id; never serialize the YAML or parser errors.
        if let data = regularData(paths.userDataDir.appendingPathComponent("user.yaml")),
           let yaml = String(data: data, encoding: .utf8), let config = try? ConfigValue.parse(yaml: yaml),
           let id = config.value(at: "var/previously_selected_schema")?.stringValue,
           id.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil {
            info["schemaID"] = id
        } else { info["schemaID"] = "未知（未记录最近选用方案）" }
        let layers: [(String, URL?)] = [
            ("defaults", paths.userDataDir.appendingPathComponent("aime/defaults")),
            ("shippedDefaults", paths.sharedDataDir?.appendingPathComponent("aime/defaults")),
            ("imported", paths.importedDir), ("generated", paths.generatedDir), ("composed", paths.userDataDir),
        ]
        info["configLayers"] = layers.map { name, url in
            ["layer": name, "files": url.map { fileMetadata($0, composed: name == "composed") } ?? []] as [String: Any]
        }
        try writeJSON(info, to: directory.appendingPathComponent("system.json"))
        // update.json can contain remote notes/URLs and unknown fields: project safe fields only.
        var update: [String: Any] = [:]
        if let data = regularData(paths.aimeDir.appendingPathComponent("update.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["autoCheck", "receiveBeta"] { if let flag = object[key] as? Bool { update[key] = flag } }
            if let date = object["lastCheck"] as? String, ISO8601DateFormatter().date(from: date) != nil { update["lastCheck"] = date }
            if let available = object["available"] as? [String: Any] {
                var release: [String: Any] = [:]
                if let version = available["version"] as? String,
                   version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil { release["version"] = version }
                if let build = available["build"] as? Int { release["build"] = build }
                if let prerelease = available["prerelease"] as? Bool { release["prerelease"] = prerelease }
                update["available"] = release
            }
            update["skipped"] = object["skipped"] == nil ? "未配置" : "已配置"
        }
        try writeJSON(update, to: directory.appendingPathComponent("update.json"))
        for (index, (kind, log)) in Self.recentLogs(safeFiles(paths.logDir)).enumerated() {
            var tail = "# \(kind)\n" + (try tailLines(log))
            for secret in secrets.sorted(by: { $0.count > $1.count }) {
                if let scheme = URLComponents(string: secret)?.scheme, ["http", "https"].contains(scheme.lowercased()) {
                    // Remove the whole endpoint, including any suffix after a configured base URL.
                    let pattern = NSRegularExpression.escapedPattern(for: secret) + #"[^\s\"'<>]*"#
                    tail = tail.replacingOccurrences(of: pattern, with: "[已脱敏]", options: .regularExpression)
                } else {
                    tail = tail.replacingOccurrences(of: secret, with: "[已脱敏]")
                }
            }
            try Self.redact(tail).write(to: directory.appendingPathComponent("log-\(index)-\(kind.replacingOccurrences(of: " ", with: "-")).txt"),
                                        atomically: true, encoding: .utf8)
        }
    }

    /// glog rolls one file per IME launch and names sort oldest-first, so pick by modification date:
    /// the newest two of each severity plus the other logs (ime-debug.log), at most eight files.
    static func recentLogs(_ files: [URL]) -> [(kind: String, url: URL)] {
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        var groups: [String: [URL]] = [:]
        for url in files {
            let name = url.lastPathComponent
            guard url.pathExtension == "log" || name.contains(".log.") else { continue }
            let kind = ["INFO", "WARNING", "ERROR", "FATAL"].first { name.contains(".log.\($0).") || url.pathExtension == $0 }
                .map { "rime \($0)" } ?? url.deletingPathExtension().lastPathComponent
            groups[kind, default: []].append(url)
        }
        let order = ["rime FATAL", "rime ERROR", "rime WARNING", "rime INFO"]
        let kinds = groups.keys.sorted { (order.firstIndex(of: $0) ?? -1, $0) < (order.firstIndex(of: $1) ?? -1, $1) }
        let picked = kinds.flatMap { kind in
            groups[kind]!.sorted { modified($0) > modified($1) }.prefix(kind.hasPrefix("rime ") ? 2 : 1).map { (kind: kind, url: $0) }
        }
        return Array(picked.prefix(8))
    }

    private func bundleInfo(_ url: URL) -> [String: Any] {
        guard let bundle = Bundle(url: url) else { return ["status": "未找到"] }
        return ["version": AppVersion.current(bundle).description, "distributionBuild": AppVersion.isDistributionBuild(bundle)]
    }

    private static var architecture: String {
        var size = MemoryLayout<Int32>.size
        var arm: Int32 = 0
        // hw.optional.arm64 remains true for an Intel process under Rosetta.
        if sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0, arm == 1 { return "Apple Silicon (arm64)" }
        return "Intel (x86_64)"
    }

    private func isSafePath(_ url: URL) -> Bool {
        var current = url.standardizedFileURL
        while current.path != "/" {
            // macOS system aliases; all workspace/file symlinks are excluded.
            if !["/var", "/tmp"].contains(current.path),
               (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return false }
            current.deleteLastPathComponent()
        }
        return true
    }

    private func safeFiles(_ directory: URL) -> [URL] {
        guard isSafePath(directory) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? [])
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values?.isRegularFile == true && values?.isSymbolicLink == false
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func regularData(_ url: URL) -> Data? {
        guard isSafePath(url),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? Int.max) <= 1_048_576 else { return nil }
        return try? Data(contentsOf: url)
    }

    private func fileMetadata(_ directory: URL, composed: Bool) -> [[String: Any]] {
        safeFiles(directory).filter { composed ? $0.lastPathComponent.hasSuffix(".custom.yaml") : $0.pathExtension == "yaml" }
            .prefix(500).map { ["name": Self.redact($0.lastPathComponent), "size": (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0] }
    }

    private func tailLines(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        // Bounded memory even for malformed or very large logs (1 MiB per file).
        try handle.seek(toOffset: size > 1_048_576 ? size - 1_048_576 : 0)
        var lines = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self).components(separatedBy: "\n")
        if size > 1_048_576 { lines.removeFirst() }
        if lines.last == "" { lines.removeLast() }
        return lines.suffix(500).joined(separator: "\n") + "\n"
    }

    static func redact(_ text: String) -> String {
        var result = text
        // Drop sensitive labelled payloads, then scrub tokens and all URL components except the host.
        for pattern in [#"(?im)^.*(?:input|preedit|composing|userdb|custom_phrase|credentials|api[_ -]?key|base[_ -]?url|prompt|commitText|输入内容|常用语)[\"' ]*\s*[:=].*$"#,
                        #"(?i)sk-[A-Za-z0-9_-]+"#, #"(?i)Bearer\s+[^\s\"'<>]+"#] {
            result = result.replacingOccurrences(of: pattern, with: "[已脱敏]", options: .regularExpression)
        }
        if let regex = try? NSRegularExpression(pattern: #"(?i)https?://[^\s\"'<>]+"#) {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let host = URLComponents(string: String(result[range]))?.host ?? "[已脱敏]"
                result.replaceSubrange(range, with: "https://\(host)/[已脱敏]")
            }
        }
        return result
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        func sanitize(_ value: Any) -> Any {
            if let string = value as? String { return Self.redact(string) }
            if let dictionary = value as? [String: Any] { return dictionary.mapValues(sanitize) }
            if let array = value as? [Any] { return array.map(sanitize) }
            return value
        }
        let data = try JSONSerialization.data(withJSONObject: sanitize(object), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
