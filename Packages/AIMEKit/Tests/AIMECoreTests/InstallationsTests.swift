import Foundation
import Testing
@testable import AIMECore

struct InstallationsTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("aime-installs-\(UUID().uuidString)")
    var user: URL { root.appendingPathComponent("home/Library/Input Methods/AIME.app") }
    var system: URL { root.appendingPathComponent("Library/Input Methods/AIME.app") }

    func make(_ url: URL, version: String, build: String, bundleID: String = AIMEInstallations.bundleID) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version, "CFBundleVersion": build]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    @Test func olderUserCopyLosesToSystemInstall() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try make(user, version: "0.1.8", build: "14")
        try make(system, version: "0.1.10", build: "17")
        let installs = AIMEInstallations(userURL: user, systemURL: system)
        #expect(installs.isDuplicate)
        #expect(installs.preferred?.url == system)
        #expect(installs.stale?.url == user)
        #expect(installs.stale?.version == "0.1.8" && installs.stale?.build == 14)
    }

    @Test func sameBuildPrefersSystemInstall() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try make(user, version: "0.1.11", build: "18")
        try make(system, version: "0.1.11", build: "18")
        let installs = AIMEInstallations(userURL: user, systemURL: system)
        #expect(installs.preferred?.url == system)
        #expect(installs.stale?.url == user)
    }

    @Test func newerDevelopmentCopyWins() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try make(user, version: "0.1.12", build: "19")
        try make(system, version: "0.1.11", build: "18")
        let installs = AIMEInstallations(userURL: user, systemURL: system)
        #expect(installs.preferred?.url == user)
        #expect(installs.stale?.url == system)
    }

    @Test func singleCopyIsNotDuplicate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try make(user, version: "0.1.11", build: "18")
        var installs = AIMEInstallations(userURL: user, systemURL: system)
        #expect(!installs.isDuplicate && installs.preferred?.url == user && installs.stale == nil)
        try FileManager.default.removeItem(at: user)
        try make(system, version: "0.1.11", build: "18")
        installs = AIMEInstallations(userURL: user, systemURL: system)
        #expect(!installs.isDuplicate && installs.preferred?.url == system && installs.stale == nil)
    }

    @Test func foreignBundleAtThePathIsIgnored() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try make(user, version: "1.0", build: "1", bundleID: "com.example.other")
        try make(system, version: "0.1.11", build: "18")
        let installs = AIMEInstallations(userURL: user, systemURL: system)
        #expect(!installs.isDuplicate && installs.preferred?.url == system)
        #expect(AIMEInstallations(userURL: root.appendingPathComponent("none.app"), systemURL: root.appendingPathComponent("none2.app")).preferred == nil)
    }
}
