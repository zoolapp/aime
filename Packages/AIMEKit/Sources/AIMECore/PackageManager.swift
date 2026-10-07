public import Foundation
internal import CryptoKit

/// Registry entry for a downloadable schema, dictionary or offline language model.
public struct DictionaryPackage: Sendable, Codable, Identifiable, Hashable {
    public enum Kind: String, Sendable, Codable { case schema, dictionary, model }

    public struct Source: Sendable, Codable, Hashable {
        /// `github-release`, immutable `github-release-asset` (repo + assetID), or `raw`.
        public var type: String
        public var repo: String?
        public var tag: String?
        public var asset: String?
        public var url: String?
        public var filename: String?
        public var assetID: Int?

        public var downloadURL: URL? {
            switch type {
            case "github-release":
                guard let repo, let tag, let asset else { return nil }
                return URL(string: "https://github.com/\(repo)/releases/download/\(tag)/\(asset)")
            case "github-release-asset":
                guard let repo, let assetID, assetID > 0 else { return nil }
                return URL(string: "https://api.github.com/repos/\(repo)/releases/assets/\(assetID)")
            default:
                return url.flatMap(URL.init(string:))
            }
        }

        public var downloadRequest: URLRequest? {
            guard let url = downloadURL else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 300)
            if type == "github-release-asset" {
                request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            }
            return request
        }
    }

    public var id: String
    public var title: String
    public var summary: String
    public var homepage: String
    public var license: String
    public var kind: Kind
    public var schemas: [String]
    public var requires: [String]
    public var source: Source
    public var sha256: String
    public var size: Int?
    /// Who the package suits (shown on the scheme card).
    public var audience: String?
    /// Editions of one scheme share a family and are shown as one card (e.g. 万象 标准 / 轻量).
    public var family: String?
    public var edition: String?
    /// Packages whose files this one replaces; installing it removes them first, after asking.
    public var conflicts: [String]?
    /// A dictionary-only update offered on another package's card (e.g. 雾凇 · 仅词库).
    public var addonFor: String?
    /// Rarely needed; listed under 高级.
    public var advanced: Bool?
    public var licenseURL: String?
    public var attribution: String?

    public var version: String {
        if source.type == "github-release-asset", let assetID = source.assetID {
            return "asset-\(assetID)"
        }
        return source.tag ?? String(sha256.prefix(7))
    }
}

public struct DictionaryRegistry: Sendable, Codable {
    public var version: Int
    public var updated: String?
    public var packages: [DictionaryPackage]

    public func package(_ id: String) -> DictionaryPackage? { packages.first { $0.id == id } }

    public static let bundled: DictionaryRegistry = {
        guard let url = CoreResources.url(forResource: "registry", withExtension: "json") ?? Bundle.module.url(forResource: "registry", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let registry = try? JSONDecoder().decode(DictionaryRegistry.self, from: data)
        else { return DictionaryRegistry(version: 0, packages: []) }
        return registry
    }()
}

/// What was installed, so packages can be upgraded or removed cleanly.
public struct InstalledPackage: Sendable, Codable, Hashable {
    public var id: String
    public var version: String
    public var sha256: String
    public var installedAt: Date
    /// Paths relative to the user data dir → sha256 of the installed file.
    public var files: [String: String]
    public var backupDir: String?
    /// Optional to keep manifests written by older AIME versions readable.
    public var sourceURL: String?
    public var license: String?
    public var licenseURL: String?
    public var attribution: String?
}

public enum PackageError: Error, Equatable, CustomStringConvertible {
    case unknownPackage(String)
    case noDownloadURL(String)
    case checksumMismatch(expected: String, actual: String)
    case downloadFailed(String)
    case extractionFailed(String)
    case notInstalled(String)

    public var description: String {
        switch self {
        case let .unknownPackage(id): "unknown package '\(id)'"
        case let .noDownloadURL(id): "package '\(id)' has no download URL"
        case let .checksumMismatch(expected, actual): "sha256 mismatch: expected \(expected), got \(actual) — refusing to install"
        case let .downloadFailed(reason): "download failed: \(reason)"
        case let .extractionFailed(reason): "could not extract archive: \(reason)"
        case let .notInstalled(id): "package '\(id)' is not installed"
        }
    }
}

/// Downloads, verifies and installs registry packages into the AIME user directory.
///
/// * Every archive is verified against the registry's pinned sha256 before anything
///   is written; a mismatch aborts the install.
/// * Files the package would overwrite that are not owned by an earlier install of
///   the same package are backed up to `aime/backup/<id>-<timestamp>/`.
/// * `*.custom.yaml`, `installation.yaml`, `user.yaml` and `build/` inside archives are
///   never installed — user customizations always win.
public struct PackageManager: Sendable {
    public let paths: AIMEPaths
    public let registry: DictionaryRegistry
    /// Legacy Data injection for small test fixtures. Production downloads use a file.
    public var fetch: @Sendable (URL) async throws -> Data {
        didSet { usesInjectedFetch = true }
    }
    private var usesInjectedFetch: Bool
    private let downloadFile: @Sendable (URLRequest) async throws -> (URL, URLResponse)

    static let protectedNames: Set<String> = ["installation.yaml", "user.yaml", "build", "sync", ".git", ".github", "__MACOSX", ".DS_Store"]

    public init(
        paths: AIMEPaths,
        registry: DictionaryRegistry = .bundled,
        fetch: (@Sendable (URL) async throws -> Data)? = nil
    ) {
        self.init(paths: paths, registry: registry, download: { request in
            try await URLSession.shared.download(for: request)
        })
        if let fetch { self.fetch = fetch }
        self.usesInjectedFetch = fetch != nil
    }

    /// File download injection is a separate overload so legacy trailing Data closures
    /// continue to bind to `fetch` rather than an optional earlier closure parameter.
    public init(
        paths: AIMEPaths,
        registry: DictionaryRegistry = .bundled,
        download: @escaping @Sendable (URLRequest) async throws -> (URL, URLResponse)
    ) {
        self.paths = paths
        self.registry = registry
        self.usesInjectedFetch = false
        self.downloadFile = download
        self.fetch = { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw PackageError.downloadFailed("HTTP \(http.statusCode) for \(url.absoluteString)")
            }
            return data
        }
    }

    // MARK: - Queries

    public func manifestURL(_ id: String) -> URL { paths.packagesDir.appendingPathComponent("\(id).json") }

    public func installed(_ id: String) -> InstalledPackage? {
        guard let data = try? Data(contentsOf: manifestURL(id)) else { return nil }
        return try? Self.decoder.decode(InstalledPackage.self, from: data)
    }

    public func installedPackages() -> [InstalledPackage] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.packagesDir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { installed(String($0.dropLast(5))) }
    }

    // MARK: - Install

    /// Downloads (or reads from cache) and installs a registry package.
    @discardableResult
    public func install(_ id: String, progress: (@Sendable (String) -> Void)? = nil) async throws -> InstalledPackage {
        guard let package = registry.package(id) else { throw PackageError.unknownPackage(id) }
        let archive = try await download(package, progress: progress)
        return try install(package, archive: archive, progress: progress)
    }

    /// Returns a verified local copy of the package payload.
    public func download(_ package: DictionaryPackage, progress: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        guard let request = package.source.downloadRequest, let url = request.url else { throw PackageError.noDownloadURL(package.id) }
        let fm = FileManager.default
        try fm.createDirectory(at: paths.cacheDir, withIntermediateDirectories: true)
        let name = package.source.filename ?? url.lastPathComponent
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else {
            throw PackageError.downloadFailed("invalid file name \(name)")
        }
        let cached = paths.cacheDir.appendingPathComponent("\(package.sha256.prefix(16))-\(name)")
        if fm.fileExists(atPath: cached.path), (try? Self.verify(package, payload: cached)) != nil {
            progress?("using cached \(name)")
            return cached
        }
        progress?("downloading \(url.absoluteString)")
        if usesInjectedFetch {
            let data = try await fetch(url)
            let digest = Self.sha256(of: data)
            guard digest == package.sha256 else {
                throw PackageError.checksumMismatch(expected: package.sha256, actual: digest)
            }
            try Self.verifyModelSize(package, actual: data.count)
            try data.write(to: cached, options: .atomic)
        } else {
            // One download call, with no retry loop. URLSession follows the asset redirect.
            let (temporary, response) = try await downloadFile(request)
            defer { try? fm.removeItem(at: temporary) }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw PackageError.downloadFailed("HTTP \(http.statusCode) for \(url.absoluteString)")
            }
            try Self.verify(package, payload: temporary)
            if fm.fileExists(atPath: cached.path) { try fm.removeItem(at: cached) }
            try fm.moveItem(at: temporary, to: cached)
        }
        return cached
    }

    /// Installs from an already-downloaded payload. The payload is re-verified.
    @discardableResult
    public func install(_ package: DictionaryPackage, archive: URL, progress: (@Sendable (String) -> Void)? = nil) throws -> InstalledPackage {
        try Self.verify(package, payload: archive)

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("aime-pkg-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        if package.kind == .model {
            guard let name = package.source.filename, name.hasSuffix(".gram"),
                  !name.contains("/"), !name.contains(".."), archive.pathExtension.lowercased() != "zip" else {
                throw PackageError.extractionFailed("a model package must contain one named .gram file")
            }
            try fm.copyItem(at: archive, to: staging.appendingPathComponent(name))
        } else if archive.pathExtension.lowercased() == "zip" {
            progress?("extracting")
            try Self.unzip(archive, to: staging)
        } else {
            let name = package.source.filename ?? archive.lastPathComponent
            guard !name.contains("/"), !name.contains(".."), !name.isEmpty else {
                throw PackageError.extractionFailed("invalid file name \(name)")
            }
            try fm.copyItem(at: archive, to: staging.appendingPathComponent(name))
        }
        let root = Self.contentRoot(of: staging)
        let files = Self.installableFiles(in: root)

        let previous = installed(package.id)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backupRoot = paths.aimeDir.appendingPathComponent("backup/\(package.id)-\(stamp)", isDirectory: true)
        var backedUp = false
        var manifestFiles: [String: String] = [:]

        progress?("installing \(files.count) files")
        var copied: [URL] = []
        var movedToBackup: [(original: URL, backup: URL, scratch: Bool)] = []
        do {
            for relative in files {
                let source = root.appendingPathComponent(relative)
                let destination = paths.userDataDir.appendingPathComponent(relative)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ensureInsideWorkspace(destination)
                if fm.fileExists(atPath: destination.path) {
                    let ownedByPrevious = previous?.files[relative].map { $0 == (try? Self.sha256(of: destination)) } ?? false
                    let backup = ownedByPrevious
                        ? fm.temporaryDirectory.appendingPathComponent("aime-pkg-old-\(UUID().uuidString)")
                        : backupRoot.appendingPathComponent(relative)
                    try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: destination, to: backup)
                    movedToBackup.append((destination, backup, ownedByPrevious))
                    if !ownedByPrevious { backedUp = true }
                }
                try fm.copyItem(at: source, to: destination)
                copied.append(destination)
                manifestFiles[relative] = try Self.sha256(of: destination)
            }
        } catch {
            // Roll back: remove what was copied, restore what was moved aside.
            for url in copied { try? fm.removeItem(at: url) }
            for (original, backup, _) in movedToBackup.reversed() { try? fm.moveItem(at: backup, to: original) }
            throw error
        }
        // Previous versions of our own files are scratch copies; user files stay backed up.
        for (_, backup, scratch) in movedToBackup where scratch {
            try? fm.removeItem(at: backup)
        }

        // Files the previous version installed that the new one no longer ships
        // (unless another package also owns them).
        let shared = filesOwnedByOtherPackages(than: package.id)
        for (relative, hash) in previous?.files ?? [:] where manifestFiles[relative] == nil && !shared.contains(relative) {
            let url = paths.userDataDir.appendingPathComponent(relative)
            if (try? Self.sha256(of: url)) == hash { try? fm.removeItem(at: url) }
        }

        let record = InstalledPackage(
            id: package.id, version: package.version, sha256: package.sha256, installedAt: Date(),
            files: manifestFiles, backupDir: backedUp ? backupRoot.path : nil,
            sourceURL: package.source.downloadURL?.absoluteString, license: package.license,
            licenseURL: package.licenseURL, attribution: package.attribution
        )
        try fm.createDirectory(at: paths.packagesDir, withIntermediateDirectories: true)
        try Self.encoder.encode(record).write(to: manifestURL(package.id), options: .atomic)
        return record
    }

    /// Removes files installed by a package. Files the user modified since are kept.
    @discardableResult
    public func uninstall(_ id: String) throws -> (removed: [String], kept: [String]) {
        guard let record = installed(id) else { throw PackageError.notInstalled(id) }
        let fm = FileManager.default
        var removed: [String] = []
        var kept: [String] = []
        let shared = filesOwnedByOtherPackages(than: id)
        for (relative, hash) in record.files.sorted(by: { $0.key < $1.key }) {
            let url = paths.userDataDir.appendingPathComponent(relative)
            if shared.contains(relative) {
                kept.append(relative)
            } else if (try? Self.sha256(of: url)) == hash {
                try fm.removeItem(at: url)
                removed.append(relative)
            } else if fm.fileExists(atPath: url.path) {
                kept.append(relative)
            }
        }
        try fm.removeItem(at: manifestURL(id))
        return (removed, kept)
    }

    // MARK: - Helpers

    static func verify(_ package: DictionaryPackage, payload: URL) throws {
        let digest = try sha256(of: payload)
        guard digest == package.sha256 else {
            throw PackageError.checksumMismatch(expected: package.sha256, actual: digest)
        }
        if package.kind == .model {
            let size = try payload.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try verifyModelSize(package, actual: size)
        }
    }

    static func verifyModelSize(_ package: DictionaryPackage, actual: Int) throws {
        if package.kind == .model, let expected = package.size, actual != expected {
            throw PackageError.downloadFailed("model size mismatch: expected \(expected), got \(actual)")
        }
    }

    func filesOwnedByOtherPackages(than id: String) -> Set<String> {
        Set(installedPackages().filter { $0.id != id }.flatMap { $0.files.keys })
    }

    /// Refuses destinations that resolve outside the user directory (e.g. through a
    /// symlinked folder) — a package must never write elsewhere.
    func ensureInsideWorkspace(_ destination: URL) throws {
        let root = paths.userDataDir.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard parent.hasPrefix(root) else { throw PackageError.extractionFailed("path escapes the user directory: \(destination.path)") }
        if (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw PackageError.extractionFailed("refusing to overwrite symlink \(destination.lastPathComponent)")
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func unzip(_ archive: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        // Drain stderr before waiting: a full pipe would otherwise deadlock both sides.
        let errorOutput = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorOutput.prefix(4096), as: UTF8.self)
            throw PackageError.extractionFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Strips a single wrapping directory (common in GitHub archives).
    static func contentRoot(of directory: URL) -> URL {
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !protectedNames.contains($0) }
        if entries.count == 1 {
            let only = directory.appendingPathComponent(entries[0])
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: only.path, isDirectory: &isDirectory), isDirectory.boolValue,
               !entries[0].hasSuffix("_dicts"), entries[0] != "lua", entries[0] != "opencc" {
                return only
            }
        }
        return directory
    }

    /// Regular files to install, relative to `root`, excluding protected names.
    static func installableFiles(in root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [String] = []
        let rootPath = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            let relative = url.standardizedFileURL.path.replacingOccurrences(of: rootPath, with: "")
            let components = relative.split(separator: "/").map(String.init)
            if components.contains(where: protectedNames.contains) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true, values?.isRegularFile == true else { continue }
            // Never touch AIME's control directory or live user databases.
            if components.first == "aime" || components.contains(where: { $0.hasSuffix(".userdb") }) { continue }
            if components.contains("..") || relative.hasPrefix("/") { continue }
            if relative.hasSuffix(".custom.yaml") || relative.hasSuffix(".userdb.txt") { continue }
            files.append(relative)
        }
        return files.sorted()
    }
}
