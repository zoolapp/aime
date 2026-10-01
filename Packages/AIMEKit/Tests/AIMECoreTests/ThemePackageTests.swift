import Foundation
import Testing
@testable import AIMECore

/// Checks the Swift side of the aime-theme contract against the fixtures shared with
/// the website (scripts/export-themes.py writes them; aime-web copies them verbatim).
@Suite struct ThemePackageTests {
    struct ValidCase: Decodable { let id: String; let canonical: String; let d: String; let url: String }
    struct InvalidCase: Decodable { let name: String; let d: String; let reason: String }

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/theme-v1")
    static func load<T: Decodable>(_ name: String) throws -> [T] {
        try JSONDecoder().decode([T].self, from: Data(contentsOf: fixtures.appendingPathComponent(name)))
    }

    @Test func matchesTheSharedFixturesByteForByte() throws {
        let cases: [ValidCase] = try Self.load("valid.json")
        #expect(cases.count == 10)
        for item in cases {
            let decoded = try ThemePackage.decode(url: URL(string: item.url)!)
            #expect(decoded.ignoredKeys.isEmpty)
            #expect(decoded.package.id == item.id)
            #expect(String(decoding: decoded.package.canonicalJSON(), as: UTF8.self) == item.canonical, "\(item.id)")
            #expect(decoded.package.payload == item.d, "\(item.id)")
            #expect(decoded.package.url.absoluteString == item.url)
        }
    }

    @Test func rejectsEveryInvalidFixture() throws {
        let cases: [InvalidCase] = try Self.load("invalid.json")
        #expect(cases.count >= 10)
        for item in cases {
            #expect(throws: ThemePackage.Failure.self, "\(item.name)") { try ThemePackage.decode(payload: item.d) }
        }
        #expect(throws: ThemePackage.Failure.reserved) {
            try ThemePackage.decode(payload: cases.first { $0.name == "reserved_id" }!.d)
        }
    }

    @Test func rejectsOtherLinksAndVersions() {
        #expect(throws: ThemePackage.Failure.notATheme) { try ThemePackage.decode(url: URL(string: "aime-ime://other?d=x")!) }
        #expect(throws: ThemePackage.Failure.notATheme) { try ThemePackage.decode(url: URL(string: "https://aime.zool.app/themes/")!) }
        #expect(throws: ThemePackage.Failure.notATheme) { try ThemePackage.decode(url: URL(string: "aime://theme?v=1&d=e30")!) }
        #expect(throws: ThemePackage.Failure.version(3)) { try ThemePackage.decode(url: URL(string: "aime-ime://theme?v=3&d=e30")!) }
    }

    @Test func dropsUnknownKeysAndNormalisesColors() throws {
        var colors = Dictionary(uniqueKeysWithValues: ThemePackage.colorKeys.map { ($0, "#112233") })
        colors["shadow_color"] = "0xFF000000"
        let object: [String: Any] = ["format": "aime-theme", "version": 1, "id": "ocean", "name": " 海\u{0007}洋 ",
                                     "colors": colors, "layout": ["corner_radius": 4]]
        let decoded = try ThemePackage.decode(json: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.package.name == "海洋")
        #expect(decoded.package.author == nil)
        #expect(decoded.package.colors["back_color"] == "0xFF112233")
        #expect(decoded.ignoredKeys == ["layout", "colors.shadow_color"])
    }

    func sample(_ id: String = "sakura_test") -> ThemePackage {
        ThemePackage(id: id, name: "测试", author: "Fixture",
                     colors: Dictionary(uniqueKeysWithValues: ThemePackage.colorKeys.map { ($0, "0xFF102030") }))
    }

    @Test func importWritesOnlyTheSchemeAndStyle() {
        let other = ConfigValue.Entry("style/aime/corner_radius", 10)
        let custom = ConfigValue.Entry("preset_color_schemes/aime_custom", .map([.init("name", "我的配色")]))
        var patch = [other, custom, .init("style/color_scheme", "aime_custom"), .init("style/color_scheme_dark", "aime_custom")]
        let plan = ThemeImportPlan(package: sample(), frontend: .map([]), generatedPatch: patch)
        #expect(!plan.isBuiltIn && plan.replaces == nil)

        plan.apply(to: &patch, activate: true, target: .light)
        #expect(patch.contains(other) && patch.contains(custom))
        #expect(patch.first { $0.key == "preset_color_schemes/sakura_test" }?.value["back_color"]?.stringValue == "0xFF102030")
        #expect(patch.first { $0.key == "style/color_scheme" }?.value.stringValue == "sakura_test")
        #expect(patch.first { $0.key == "style/color_scheme_dark" }?.value.stringValue == "aime_custom")
        #expect(patch.count == 5)
    }

    @Test func importOnlyLeavesTheSelectionAlone() {
        var patch: [ConfigValue.Entry] = [.init("style/color_scheme", "graphite")]
        ThemeImportPlan(package: sample(), frontend: .map([]), generatedPatch: patch).apply(to: &patch, activate: false, target: .both)
        #expect(patch.first { $0.key == "style/color_scheme" }?.value.stringValue == "graphite")
        #expect(patch.contains { $0.key == "preset_color_schemes/sakura_test" })
    }

    @Test func builtInIDIsSelectedNotWritten() {
        let frontend = ConfigValue.map([.init("preset_color_schemes", .map([.init("sakura", .map([.init("name", "樱花")]))]))])
        var patch: [ConfigValue.Entry] = []
        let plan = ThemeImportPlan(package: sample("sakura"), frontend: frontend, generatedPatch: patch)
        #expect(plan.isBuiltIn)
        plan.apply(to: &patch, activate: true, target: .both)
        #expect(!patch.contains { $0.key.hasPrefix("preset_color_schemes/") })
        #expect(patch.filter { $0.value.stringValue == "sakura" }.count == 2)
    }

    @Test func reimportReportsTheReplacedTheme() {
        var patch: [ConfigValue.Entry] = []
        let first = ThemeImportPlan(package: sample(), frontend: .map([]), generatedPatch: patch)
        first.apply(to: &patch, activate: false, target: .both)
        let frontend = ConfigValue.map([.init("preset_color_schemes", .map([.init("sakura_test", sample().schemeValue)]))])
        let second = ThemeImportPlan(package: sample(), frontend: frontend, generatedPatch: patch)
        #expect(!second.isBuiltIn)
        #expect(second.replaces == "测试")
        second.apply(to: &patch, activate: false, target: .both)
        #expect(patch.filter { $0.key == "preset_color_schemes/sakura_test" }.count == 1)
    }

    @Test func readsLayoutAndAdoptsItOnRequest() throws {
        let cases: [ValidCase] = try Self.load("valid.json")
        let decoded = try ThemePackage.decode(url: URL(string: cases.first { $0.id == "sakura_test" }!.url)!)
        #expect(decoded.package.version == 2)
        #expect(decoded.package.layout?["corner_radius"] == 14)
        #expect(decoded.package.layout?["hilited_corner_radius"] == 0)
        #expect(decoded.package.schemeValue["font_point"]?.doubleValue == 18)

        var patch: [ConfigValue.Entry] = [.init("style/aime/font_point", 16), .init("style/aime/font_face", "PingFang SC")]
        let plan = ThemeImportPlan(package: decoded.package, frontend: .map([]), generatedPatch: patch)
        plan.apply(to: &patch, activate: false, target: .light)
        #expect(patch.first { $0.key == "style/aime/font_point" }?.value.doubleValue == 16)
        plan.apply(to: &patch, activate: false, target: .light, adoptLayout: true)
        #expect(patch.filter { $0.key == "style/aime/font_point" }.map(\.value.doubleValue) == [18])
        #expect(patch.first { $0.key == "style/aime/corner_radius" }?.value.doubleValue == 14)
        #expect(patch.contains { $0.key == "style/aime/font_face" })

        let v1 = try ThemePackage.decode(url: URL(string: cases.first { $0.id == "low_contrast" }!.url)!)
        #expect(v1.package.version == 1 && v1.package.layout == nil)
    }
}
