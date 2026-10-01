public import Foundation
import CryptoKit
import Security

/// The release manifest published at `get.zool.app/<product>/latest.json`.
/// Only this public file is requested; nothing about the user or their input is sent.
public struct AppRelease: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public var name: String
        public var size: Int?
        public var sha256: String?
    }

    public var product: String
    public var version: String
    /// Build number; lets a re-signed build of the same version count as an update.
    public var build: Int?
    public var date: String?
    public var prerelease: Bool?
    public var notes: String?
    /// Releases needing a newer macOS are not offered ("26.0").
    public var minimumSystemVersion: String?
    public var `default`: String?
    public var files: [String: File]

    public var appVersion: AppVersion { AppVersion(version, build: build) }

    public func supportsThisSystem(_ system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        guard let minimum = minimumSystemVersion else { return true }
        let running = AppVersion("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")
        return !(running < AppVersion(minimum))
    }

    /// The installer package (`pkg`), or the default file.
    public var installer: File? { files["pkg"] ?? self.default.flatMap { files[$0] } }

    public func url(for file: File, base: URL = AppUpdateChecker.downloadBase) -> URL {
        base.appendingPathComponent(product).appendingPathComponent(version).appendingPathComponent(file.name)
    }
}

/// `MARKETING_VERSION` plus `CURRENT_PROJECT_VERSION`, compared numerically.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public var parts: [Int]
    public var build: Int?
    public var string: String

    public init(_ version: String, build: Int? = nil) {
        string = version
        parts = version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        self.build = build
    }

    /// The running app's version from its Info.plist.
    public static func current(_ bundle: Bundle = .main) -> AppVersion {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init)
        return AppVersion(version, build: build)
    }

    public var description: String { build.map { "\(string) (\($0))" } ?? string }

    /// Whether this copy was signed by AIME's team (a release), not an ad-hoc development
    /// build. Development builds skip the automatic check and never offer an "update".
    public static func isDistributionBuild(_ bundle: Bundle = .main) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return false }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String == AppUpdateChecker.teamID
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        // Same version: a build number only decides when both sides have one.
        guard let left = lhs.build, let right = rhs.build else { return false }
        return left < right
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// Persisted update preferences and the last result, shared by the input method
/// (daily background check) and the settings app. Stored in `aime/update.json`.
public struct AppUpdateState: Codable, Sendable, Equatable {
    public var autoCheck = true
    public var lastCheck: Date?
    public var available: AppRelease?
    /// A version the user chose to skip ("version (build)").
    public var skipped: String?

    public init() {}

    public static func load(_ paths: AIMEPaths) -> AppUpdateState {
        guard let data = try? Data(contentsOf: file(paths)),
              let state = try? decoder.decode(AppUpdateState.self, from: data) else { return AppUpdateState() }
        return state
    }

    public func save(_ paths: AIMEPaths) throws {
        try FileManager.default.createDirectory(at: paths.aimeDir, withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: Self.file(paths), options: .atomic)
    }

    /// The available release if it is newer than `current` and not skipped.
    public func pending(current: AppVersion) -> AppRelease? {
        guard let available, current < available.appVersion, skipped != available.appVersion.description else { return nil }
        return available
    }

    public func isDue(now: Date = Date(), interval: TimeInterval = 24 * 3600) -> Bool {
        autoCheck && (lastCheck.map { now.timeIntervalSince($0) >= interval } ?? true)
    }

    static func file(_ paths: AIMEPaths) -> URL { paths.aimeDir.appendingPathComponent("update.json") }
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public enum AppUpdateError: Error, LocalizedError, Equatable {
    case badResponse(Int)
    case noInstaller
    case checksumMismatch
    case untrustedPackage(String)
    case untrustedManifest

    public var errorDescription: String? {
        switch self {
        case let .badResponse(code): "更新服务器返回 \(code)"
        case .noInstaller: "此版本没有安装包"
        case .checksumMismatch: "安装包校验失败（SHA-256 不一致），已删除"
        case let .untrustedPackage(detail): "安装包签名不可信：\(detail)"
        case .untrustedManifest: "版本清单签名校验失败，已忽略"
        }
    }
}

/// Fetches the manifest, downloads and verifies the installer. Installation itself is
/// left to macOS Installer, which asks for the administrator password.
public struct AppUpdateChecker: Sendable {
    public static let downloadBase = URL(string: "https://get.zool.app")!
    public static let product = "aime"
    /// Team that signs AIME installers; downloaded packages must carry this signature.
    public static let teamID = "PX694P4CGY"
    /// Ed25519 key that signs latest.json (scripts/sign-manifest.swift); the manifest is
    /// trusted only with a valid latest.json.sig, whatever host serves it.
    public static let manifestPublicKey = "O7FCOIU2KiHoIyJnCh4tcZRCmgaiMtElud2wmuIMglw="

    public var manifestURL: URL
    public var session: URLSession

    public init(manifestURL: URL = downloadBase.appendingPathComponent(product).appendingPathComponent("latest.json"),
                session: URLSession = .shared) {
        self.manifestURL = manifestURL
        self.session = session
    }

    public func fetchLatest() async throws -> AppRelease {
        let data = try await get(manifestURL)
        let signature = try await get(manifestURL.appendingPathExtension("sig"))
        guard Self.verify(manifest: data, signature: signature) else { throw AppUpdateError.untrustedManifest }
        return try JSONDecoder().decode(AppRelease.self, from: data)
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw AppUpdateError.badResponse(http.statusCode) }
        return data
    }

    /// `signature` is the base64 text of latest.json.sig.
    static func verify(manifest: Data, signature: Data, publicKey: String = manifestPublicKey) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let text = String(data: signature, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let raw = Data(base64Encoded: text) else { return false }
        return key.isValidSignature(raw, for: manifest)
    }

    /// Checks once, records the result in `state` and returns the release when newer.
    @discardableResult
    public func check(paths: AIMEPaths, current: AppVersion, now: Date = Date()) async throws -> AppRelease? {
        let latest = try await fetchLatest()
        var state = AppUpdateState.load(paths)
        state.lastCheck = now
        state.available = current < latest.appVersion && latest.supportsThisSystem() ? latest : nil
        try state.save(paths)
        return state.pending(current: current)
    }

    /// Downloads the installer into `aime/cache/updates`, verifying size and SHA-256.
    public func download(_ release: AppRelease, paths: AIMEPaths,
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard let file = release.installer else { throw AppUpdateError.noInstaller }
        let directory = paths.cacheDir.appendingPathComponent("updates", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(file.name)
        if let sha = file.sha256, FileManager.default.fileExists(atPath: destination.path),
           (try? Self.sha256(of: destination)) == sha.lowercased() {
            return destination
        }
        let (bytes, response) = try await session.bytes(from: release.url(for: file))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw AppUpdateError.badResponse(http.statusCode) }
        let partial = destination.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        var hasher = SHA256()
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var received = 0
        let expected = file.size ?? Int(response.expectedContentLength)
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 16 {
                    hasher.update(data: buffer)
                    try handle.write(contentsOf: buffer)
                    received += buffer.count
                    buffer.removeAll(keepingCapacity: true)
                    if expected > 0 { progress?(Double(received) / Double(expected)) }
                }
            }
            hasher.update(data: buffer)
            try handle.write(contentsOf: buffer)
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let sha = file.sha256, digest != sha.lowercased() {
            try? FileManager.default.removeItem(at: partial)
            throw AppUpdateError.checksumMismatch
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        progress?(1)
        return destination
    }

    /// Requires a Developer ID Installer signature from AIME's team, checked with pkgutil.
    public static func verifySignature(of package: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        process.arguments = ["--check-signature", package.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0, isTrusted(pkgutilOutput: output) else {
            let reason = output.split(separator: "\n").first { $0.contains("Status:") }.map { $0.trimmingCharacters(in: .whitespaces) }
            throw AppUpdateError.untrustedPackage(reason ?? "没有签名")
        }
    }

    static func isTrusted(pkgutilOutput output: String) -> Bool {
        output.contains("signed by a developer certificate issued by Apple for distribution")
            && output.contains("Developer ID Installer:") && output.contains("(\(teamID))")
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
