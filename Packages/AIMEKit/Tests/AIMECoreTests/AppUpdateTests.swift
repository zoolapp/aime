import CryptoKit
import Foundation
import Testing
@testable import AIMECore

@Suite struct AppUpdateTests {
    @Test func comparesVersionsAndBuilds() {
        #expect(AppVersion("0.1.0") < AppVersion("0.1.1"))
        #expect(AppVersion("0.9.0") < AppVersion("0.10.0"))
        #expect(AppVersion("1.0") == AppVersion("1.0.0"))
        #expect(AppVersion("0.1.0", build: 1) < AppVersion("0.1.0", build: 2))
        // Without a build number on one side, the same version is not an update.
        #expect(!(AppVersion("0.1.0", build: 1) < AppVersion("0.1.0")))
        #expect(!(AppVersion("0.2.0", build: 9) < AppVersion("0.1.0", build: 10)))
        #expect(AppVersion("0.1.0", build: 2).description == "0.1.0 (2)")
    }

    @Test func ordersPrereleasesUsingSemver() {
        let versions = ["0.2.0-alpha", "0.2.0-alpha.1", "0.2.0-alpha.beta", "0.2.0-beta", "0.2.0-beta.1",
                        "0.2.0-beta.2", "0.2.0-beta.11", "0.2.0-rc.1", "0.2.0"]
        for (left, right) in zip(versions, versions.dropFirst()) {
            #expect(AppVersion(left, build: 999) < AppVersion(right, build: 1))
        }
        #expect(AppVersion("0.2.0-beta.2", build: 1) < AppVersion("0.2.0-beta.2", build: 2))
        #expect(AppVersion("0.2.0+metadata") == AppVersion("0.2.0+other"))
        #expect(AppVersion("0.2.0-beta.999999999999999999999") < AppVersion("0.2.0-beta.1000000000000000000000"))
    }

    @Test func oldStateDefaultsToStableAndFiltersCachedPrereleases() throws {
        var state = try JSONDecoder().decode(AppUpdateState.self, from: Data(#"{"autoCheck":false,"skipped":"0.1.0 (3)"}"#.utf8))
        #expect(!state.receiveBeta && !state.autoCheck && state.skipped == "0.1.0 (3)")
        #expect(state.manifestURL.lastPathComponent == "latest.json")
        state.available = AppRelease(product: "aime", version: "0.2.0-beta.1", prerelease: false, files: [:])
        #expect(state.pending(current: AppVersion("0.1.0")) == nil)
        state.available = AppRelease(product: "aime", version: "0.2.0", prerelease: true, files: [:])
        #expect(state.pending(current: AppVersion("0.1.0")) == nil)
        state.setReceiveBeta(true)
        #expect(state.available == nil && state.skipped == nil && state.lastCheck == nil)
        #expect(state.manifestURL.lastPathComponent == "latest-beta.json")
        state.available = AppRelease(product: "aime", version: "0.2.0", files: [:])
        #expect(state.pending(current: AppVersion("0.2.0-beta.2", build: 999)) != nil)
        state.setReceiveBeta(false)
        #expect(state.available == nil && !state.receiveBeta)
    }

    @Test func fullReleaseVersionIsReadFromBundleMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "test.aime.beta", "CFBundleShortVersionString": "0.2.0",
                     "CFBundleVersion": "3", "AIMEReleaseVersion": "0.2.0-beta.2"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        let bundle = try #require(Bundle(url: root))
        #expect(AppVersion.current(bundle).description == "0.2.0-beta.2 (3)")
    }

    @Test func decodesTheManifest() throws {
        let json = """
        {"product":"aime","version":"0.1.0","build":2,"date":"2026-10-01","prerelease":true,"default":"pkg",
         "files":{"pkg":{"name":"AIME-0.1.0.pkg","size":10,"sha256":"ab"},"sums":{"name":"SHA256SUMS.txt"}}}
        """
        let release = try JSONDecoder().decode(AppRelease.self, from: Data(json.utf8))
        #expect(release.appVersion > AppVersion("0.1.0", build: 1))
        #expect(release.installer?.name == "AIME-0.1.0.pkg")
        #expect(release.url(for: release.installer!).absoluteString == "https://get.zool.app/aime/0.1.0/AIME-0.1.0.pkg")
    }

    @Test func stateRoundTripsAndSkips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = AIMEPaths(userDataDir: dir)
        var state = AppUpdateState.load(paths)
        #expect(state.autoCheck && state.isDue())
        let release = AppRelease(product: "aime", version: "0.2.0", build: 3, files: ["pkg": .init(name: "AIME-0.2.0.pkg")])
        state.available = release
        state.lastCheck = Date(timeIntervalSince1970: 0)
        try state.save(paths)

        var loaded = AppUpdateState.load(paths)
        #expect(loaded == state)
        #expect(loaded.pending(current: AppVersion("0.1.0", build: 1)) == release)
        #expect(loaded.pending(current: AppVersion("0.2.0", build: 3)) == nil)
        loaded.skipped = release.appVersion.description
        #expect(loaded.pending(current: AppVersion("0.1.0", build: 1)) == nil)
        #expect(!loaded.isDue(now: Date(timeIntervalSince1970: 3600)))
        #expect(loaded.isDue(now: Date(timeIntervalSince1970: 90000)))
        loaded.autoCheck = false
        #expect(!loaded.isDue(now: Date(timeIntervalSince1970: 90000)))
    }

    @Test func trustsOnlyTheTeamsDeveloperIDInstaller() {
        let signed = """
        Package "AIME-0.1.0.pkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Notarization: trusted by the Apple notary service
           Certificate Chain:
            1. Developer ID Installer: Zool LLC (PX694P4CGY)
        """
        #expect(AppUpdateChecker.isTrusted(pkgutilOutput: signed))
        #expect(!AppUpdateChecker.isTrusted(pkgutilOutput: signed.replacingOccurrences(of: "PX694P4CGY", with: "ABCDEFGHIJ")))
        #expect(!AppUpdateChecker.isTrusted(pkgutilOutput: "Package \"x.pkg\":\n   Status: no signature"))
    }
}

@Suite struct ManifestSignatureTests {
    @Test func acceptsOnlyAValidSignatureFromTheKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let manifest = Data(#"{"product":"aime","version":"0.2.0","files":{}}"#.utf8)
        let signature = Data((try key.signature(for: manifest).base64EncodedString() + "\n").utf8)
        #expect(AppUpdateChecker.verify(manifest: manifest, signature: signature, publicKey: publicKey))
        #expect(!AppUpdateChecker.verify(manifest: manifest + Data(" ".utf8), signature: signature, publicKey: publicKey))
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(!AppUpdateChecker.verify(manifest: manifest, signature: signature, publicKey: other))
        #expect(!AppUpdateChecker.verify(manifest: manifest, signature: Data("not base64".utf8), publicKey: publicKey))
    }

    @Test func respectsTheMinimumSystem() {
        var release = AppRelease(product: "aime", version: "0.2.0", files: [:])
        release.minimumSystemVersion = "27.1"
        #expect(!release.supportsThisSystem(OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)))
        #expect(release.supportsThisSystem(OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0)))
        release.minimumSystemVersion = nil
        #expect(release.supportsThisSystem(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)))
    }
}

/// Serves canned responses for update tests (no network).
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated(unsafe) static var onRequest: (@Sendable (URLRequest) -> Void)?
    override func startLoading() {
        Self.onRequest?(request)
        let (status, body) = Self.responses[request.url!.absoluteString] ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct AppUpdateNetworkTests {
    let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }()
    let manifestURL = URL(string: "https://get.example/aime/latest.json")!

    func temporaryPaths() -> AIMEPaths {
        AIMEPaths(userDataDir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test func rejectsAnUnsignedManifest() async {
        StubProtocol.responses = [manifestURL.absoluteString: (200, Data(#"{"product":"aime","version":"9.0.0","files":{}}"#.utf8))]
        let checker = AppUpdateChecker(manifestURL: manifestURL, session: session)
        await #expect(throws: AppUpdateError.badResponse(404)) { try await checker.fetchLatest() }
        StubProtocol.responses[manifestURL.absoluteString + ".sig"] = (200, Data("AAAA\n".utf8))
        await #expect(throws: AppUpdateError.untrustedManifest) { try await checker.fetchLatest() }
    }

    @Test func channelRoutingSignatureAndStableFiltering() async throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.userDataDir) }
        let key = Curve25519.Signing.PrivateKey()
        var checker = AppUpdateChecker(session: session)
        checker.verificationKey = key.publicKey.rawRepresentation.base64EncodedString()
        let beta = Data(#"{"product":"aime","version":"0.2.0-beta.2","prerelease":false,"files":{}}"#.utf8)
        let signature = try key.signature(for: beta).base64EncodedString()
        var state = AppUpdateState()
        // Only the selected URL and its signature are available; a wrong route fails.
        state.receiveBeta = true
        try state.save(paths)
        let url = state.manifestURL.absoluteString
        StubProtocol.responses = [url: (200, beta), url + ".sig": (200, Data(signature.utf8))]
        #expect(try await checker.check(paths: paths, current: AppVersion("0.1.0"))?.version == "0.2.0-beta.2")
        state.setReceiveBeta(false)
        try state.save(paths)
        let stableURL = state.manifestURL.absoluteString
        StubProtocol.responses = [stableURL: (200, beta), stableURL + ".sig": (200, Data(signature.utf8))]
        #expect(try await checker.check(paths: paths, current: AppVersion("0.1.0")) == nil)
        #expect(AppUpdateState.load(paths).available == nil)
        state.setReceiveBeta(true)
        try state.save(paths)
        StubProtocol.responses = [url: (200, beta), url + ".sig": (200, Data("invalid".utf8))]
        await #expect(throws: AppUpdateError.untrustedManifest) { try await checker.check(paths: paths, current: AppVersion("0.1.0")) }
    }

    @Test func changingChannelDiscardsAnInflightResponse() async throws {
        let paths = temporaryPaths()
        defer { StubProtocol.onRequest = nil; try? FileManager.default.removeItem(at: paths.userDataDir) }
        var state = AppUpdateState()
        state.receiveBeta = true
        try state.save(paths)
        let key = Curve25519.Signing.PrivateKey()
        var checker = AppUpdateChecker(session: session)
        checker.verificationKey = key.publicKey.rawRepresentation.base64EncodedString()
        let data = Data(#"{"product":"aime","version":"0.2.0-beta.1","files":{}}"#.utf8)
        let url = state.manifestURL.absoluteString
        StubProtocol.responses = [url: (200, data), url + ".sig": (200, Data(try key.signature(for: data).base64EncodedString().utf8))]
        StubProtocol.onRequest = { request in
            if request.url?.pathExtension == "sig" {
                var changed = AppUpdateState.load(paths)
                changed.setReceiveBeta(false)
                try? changed.save(paths)
            }
        }
        #expect(try await checker.check(paths: paths, current: AppVersion("0.1.0")) == nil)
        #expect(!AppUpdateState.load(paths).receiveBeta)
        #expect(AppUpdateState.load(paths).lastCheck == nil)
    }

    @Test func downloadVerifiesTheChecksumAndCleansUp() async throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.userDataDir) }
        let payload = Data(repeating: 7, count: 200_000)
        let file = AppRelease.File(name: "AIME-9.0.0.pkg", size: payload.count, sha256: String(repeating: "0", count: 64))
        let release = AppRelease(product: "aime", version: "9.0.0", files: ["pkg": file])
        StubProtocol.responses = [release.url(for: file).absoluteString: (200, payload)]
        let checker = AppUpdateChecker(manifestURL: manifestURL, session: session)
        await #expect(throws: AppUpdateError.checksumMismatch) { _ = try await checker.download(release, paths: paths) }
        let updates = paths.cacheDir.appendingPathComponent("updates")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: updates.path)) ?? []
        #expect(left.isEmpty, "partial download removed: \(left)")

        StubProtocol.responses = [:]
        await #expect(throws: AppUpdateError.badResponse(404)) { _ = try await checker.download(release, paths: paths) }
    }

    @Test func downloadKeepsAVerifiedPackage() async throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.userDataDir) }
        let payload = Data("installer bytes".utf8)
        let sha = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let file = AppRelease.File(name: "AIME-9.0.0.pkg", size: payload.count, sha256: sha)
        let release = AppRelease(product: "aime", version: "9.0.0", files: ["pkg": file])
        StubProtocol.responses = [release.url(for: file).absoluteString: (200, payload)]
        let url = try await AppUpdateChecker(manifestURL: manifestURL, session: session).download(release, paths: paths)
        #expect(try Data(contentsOf: url) == payload)
    }
}
