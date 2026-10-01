import Foundation
import Testing
@testable import AIMECore
import RimeKit

/// Proves the shim → imported → generated layering against a real librime deploy.
@MainActor
@Suite(.serialized)
struct PatchLayeringTests {
    let shared: URL
    let paths: AIMEPaths
    let layers: ConfigLayers

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aime-layers-\(UUID().uuidString)")
        shared = root.appendingPathComponent("shared")
        paths = AIMEPaths(userDataDir: root.appendingPathComponent("user"), sharedDataDir: root.appendingPathComponent("shared"))
        layers = ConfigLayers(paths: paths)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.userDataDir, withIntermediateDirectories: true)
        try """
        config_version: "test"
        schema_list: []
        menu:
          page_size: 5
          alternative_select_keys: "123456789"
        switcher:
          caption: 〔方案选单〕
          hotkeys: [F4]
        engine:
          processors: [ascii_composer, speller]
          translators: [script_translator]
        """.write(to: shared.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
    }

    private func deploy() throws -> ConfigValue {
        let engine = RimeEngine.shared
        engine.initialize(RimeTraits(sharedDataDir: shared, userDataDir: paths.userDataDir, minLogLevel: 2))
        try layers.prepareForDeploy()
        engine.deployAndWait()
        return try ConfigValue.load(contentsOf: paths.builtConfig("default"))
    }

    static let handWritten = """
    # 我的配置（注释必须被保留）
    patch:
      menu/page_size: 9
      switcher/caption: 「方案选单」
    """

    @Test func importedLayerApplies() throws {
        try FileManager.default.createDirectory(at: paths.userDataDir, withIntermediateDirectories: true)
        try Self.handWritten.write(to: layers.shimURL(.default), atomically: true, encoding: .utf8)
        try layers.installShim(.default)

        // The hand-written file moved verbatim into the imported layer.
        #expect(try String(contentsOf: layers.importedURL(.default), encoding: .utf8) == Self.handWritten)
        #expect(layers.hasForeignCustomFile(.default) == false)

        let built = try deploy()
        #expect(built.value(at: "menu/page_size")?.intValue == 9)
        #expect(built.value(at: "switcher/caption")?.stringValue == "「方案选单」")
    }

    @Test func generatedLayerOverridesImported() throws {
        try Self.handWritten.write(to: layers.shimURL(.default), atomically: true, encoding: .utf8)
        try layers.setGenerated(.default, keypath: "menu/page_size", value: 5)
        #expect(layers.generatedValue(.default, keypath: "menu/page_size") == 5)

        var built = try deploy()
        #expect(built.value(at: "menu/page_size")?.intValue == 5)
        // Untouched imported values survive.
        #expect(built.value(at: "switcher/caption")?.stringValue == "「方案选单」")

        try layers.setGenerated(.default, keypath: "menu/page_size", value: nil)
        built = try deploy()
        #expect(built.value(at: "menu/page_size")?.intValue == 9)
    }

    @Test func defaultsLayerAppendsWithoutClobbering() throws {
        let sharedDefaults = shared.appendingPathComponent("aime/defaults")
        try FileManager.default.createDirectory(at: sharedDefaults, withIntermediateDirectories: true)
        try "patch:\n  engine/translators/+:\n    - table_translator@extra\n".write(
            to: sharedDefaults.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
        try Self.handWritten.write(to: layers.shimURL(.default), atomically: true, encoding: .utf8)
        try layers.installShim(.default)
        let built = try deploy()
        #expect(built.value(at: "engine/processors")?.listValue == ["ascii_composer", "speller"])
        #expect(built.value(at: "engine/translators")?.listValue == ["script_translator", "table_translator@extra"])
        #expect(built.value(at: "menu/page_size")?.intValue == 9)
        #expect(built.value(at: "menu/alternative_select_keys")?.stringValue == "123456789")
    }

    @Test func composeRespectsLayerPrecedence() {
        let composed = ConfigLayers.compose([
            [.init("style/font_point", 14), .init("engine/translators/+", ["a"])],
            [.init("style", .map([.init("font_point", 16)])), .init("engine/translators/+", ["b"])],
            [.init("style/color_scheme", "ink")],
        ])
        #expect(composed.map(\.key) == ["engine/translators/+", "style", "style/color_scheme"])
        #expect(composed.first?.value == ["a", "b"])
    }

    @Test func collectionMapsMergeInsteadOfReplacing() {
        let composed = ConfigLayers.compose([
            [.init("preset_color_schemes/aime_light", .map([.init("name", "AIME")]))],
            [.init("preset_color_schemes", .map([.init("mac_light", .map([.init("name", "Mac")]))])),
             .init("style", .map([.init("color_scheme", "mac_light")]))],
        ])
        #expect(composed.map(\.key) == ["preset_color_schemes/aime_light", "preset_color_schemes/mac_light", "style"])
    }

    @Test func sameLayerParentAndChildBothSurvive() {
        let composed = ConfigLayers.compose([[
            .init("style/font_point", 22), .init("style", .map([.init("color_scheme", "dark")])),
        ]])
        #expect(Set(composed.map(\.key)) == ["style/font_point", "style"])
    }

    @Test func appendFoldsIntoEarlierReplacement() {
        let composed = ConfigLayers.compose([
            [.init("items/=", ["A"])],
            [.init("items/+", ["B"])],
        ])
        #expect(composed.map(\.key) == ["items/="])
        #expect(composed.first?.value == ["A", "B"])
    }

    @Test func corruptLayerIsAnErrorNotAnEmptyPatch() throws {
        try FileManager.default.createDirectory(at: paths.importedDir, withIntermediateDirectories: true)
        try "patch:\n  menu/page_size: 9\n".write(to: layers.importedURL(.default), atomically: true, encoding: .utf8)
        try layers.installShim(.default)
        let good = try String(contentsOf: layers.shimURL(.default), encoding: .utf8)
        try "patch: [unclosed\n".write(to: layers.importedURL(.default), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try layers.installShim(.default) }
        #expect(throws: (any Error).self) { try layers.setGenerated(.default, keypath: "menu/page_size", value: 5) }
        // The last good shim is kept.
        #expect(try String(contentsOf: layers.shimURL(.default), encoding: .utf8) == good)
    }

    @Test func foreignCustomFileIsBackedUpNotDeleted() throws {
        try FileManager.default.createDirectory(at: paths.importedDir, withIntermediateDirectories: true)
        try "patch: {a: 1}\n".write(to: layers.importedURL(.default), atomically: true, encoding: .utf8)
        try "patch: {b: 2}\n".write(to: layers.shimURL(.default), atomically: true, encoding: .utf8)
        try layers.installShim(.default)
        let backups = FileManager.default.enumerator(atPath: paths.aimeDir.appendingPathComponent("backup").path)?.allObjects as? [String] ?? []
        #expect(backups.contains { $0.hasSuffix("default.custom.yaml") })
        #expect(try String(contentsOf: layers.importedURL(.default), encoding: .utf8).contains("b: 2"))
    }

    @Test func worksWithoutImportedLayer() throws {
        try layers.setGenerated(.default, keypath: "menu/page_size", value: 7)
        try layers.setGenerated(.default, keypath: "ascii_composer/switch_key", value: .map([.init("Shift_L", "commit_code")]))
        let built = try deploy()
        #expect(built.value(at: "menu/page_size")?.intValue == 7)
        // Sibling keys of patched keypaths must survive.
        #expect(built.value(at: "menu/alternative_select_keys")?.stringValue == "123456789")
        #expect(built.value(at: "switcher/hotkeys")?.listValue?.count == 1)
        #expect(built.value(at: "ascii_composer/switch_key/Shift_L")?.stringValue == "commit_code")
        #expect(layers.managedTargets() == [.default])
    }
}
