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
