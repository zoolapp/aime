import Foundation
import Testing
@testable import AIMECore

struct LanguageModelSettingsTests {
    private struct Fixture {
        let root: URL
        let paths: AIMEPaths
        var store: SettingsStore { SettingsStore(paths: paths) }
        let target = ConfigTarget.schema("rime_ice")

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("aime-model-settings-\(UUID().uuidString)")
            paths = AIMEPaths(userDataDir: root.appendingPathComponent("user"), sharedDataDir: root.appendingPathComponent("shared"))
            try FileManager.default.createDirectory(at: paths.stagingDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: paths.sharedDataDir!, withIntermediateDirectories: true)
            try "schema_list:\n  - schema: rime_ice\n".write(to: paths.builtConfig("default"), atomically: true, encoding: .utf8)
            try "schema:\n  schema_id: rime_ice\ntranslator:\n  contextual_suggestions: false\n".write(
                to: paths.sharedDataDir!.appendingPathComponent("rime_ice.schema.yaml"), atomically: true, encoding: .utf8)
        }

        func model(_ name: String = "wanxiang-lts-zh-hans", shared: Bool = false, content: String = "fixture") throws {
            try Data(content.utf8).write(to: (shared ? paths.sharedDataDir! : paths.userDataDir).appendingPathComponent("\(name).gram"))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func selectingLocalModelSuppliesCompleteGrammarWithoutEnablingContextualSuggestions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.model()
        try fixture.store.setLanguageModel("wanxiang-lts-zh-hans")
        let patch = try fixture.store.layers.generatedPatch(fixture.target)
        let values = Dictionary(uniqueKeysWithValues: patch.map { ($0.key, $0.value) })
        #expect(values["grammar/language"] == "wanxiang-lts-zh-hans")
        #expect(values["grammar/collocation_max_length"] == 6)
        #expect(values["grammar/collocation_min_length"] == 2)
        #expect(values["grammar/collocation_penalty"] == -14)
        #expect(values["grammar/non_collocation_penalty"] == -6)
        #expect(values["grammar/weak_collocation_penalty"] == -100)
        #expect(values["grammar/rear_penalty"] == -18)
        #expect(values["translator/contextual_suggestions"] == nil)
        #expect(fixture.store.layers.dirtyTargets() == ["rime_ice.schema"])
    }

    @Test func catalogWriteAndResetUseValidatedModelSettings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let setting = try #require(fixture.store.catalog.setting("grammar.language"))
        #expect(throws: SettingsStore.WriteError.self) { try fixture.store.set(1, for: setting) }
        #expect(!FileManager.default.fileExists(atPath: fixture.store.layers.generatedURL(fixture.target).path))
        try fixture.model()
        try fixture.store.set("wanxiang-lts-zh-hans", for: setting)
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "grammar/rear_penalty") == -18)
        try fixture.store.reset(setting)
        #expect(try fixture.store.layers.generatedPatch(fixture.target).isEmpty)
    }

    @Test(arguments: ["../outside", "/outside", ".", "..", "bad/name", "bad\\name", " name", "bad\nname", String(repeating: "a", count: 201)])
    func unsafeNamesNeverCreateGeneratedConfiguration(name: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(throws: LanguageModelSettingsError.invalidName(name)) { try fixture.store.setLanguageModel(name) }
        #expect(!FileManager.default.fileExists(atPath: fixture.store.layers.generatedURL(fixture.target).path))
    }

    @Test func rejectsMissingEmptyDirectoryAndSymlinkModelsBeforeWriting() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(throws: LanguageModelSettingsError.missingModel("missing")) { try fixture.store.setLanguageModel("missing") }
        try fixture.model("empty", content: "")
        #expect(throws: LanguageModelSettingsError.missingModel("empty")) { try fixture.store.setLanguageModel("empty") }
        try FileManager.default.createDirectory(at: fixture.paths.userDataDir.appendingPathComponent("directory.gram"), withIntermediateDirectories: true)
        #expect(throws: LanguageModelSettingsError.missingModel("directory")) { try fixture.store.setLanguageModel("directory") }
        try fixture.model("real")
        try FileManager.default.createSymbolicLink(at: fixture.paths.userDataDir.appendingPathComponent("linked.gram"), withDestinationURL: fixture.paths.userDataDir.appendingPathComponent("real.gram"))
        #expect(throws: LanguageModelSettingsError.missingModel("linked")) { try fixture.store.setLanguageModel("linked") }
        #expect(!FileManager.default.fileExists(atPath: fixture.store.layers.generatedURL(fixture.target).path))
    }

    @Test func sharedModelWorksButAnEmptyUserModelShadowsIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.model("shared-model", shared: true)
        try fixture.store.setLanguageModel("shared-model")
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "grammar/language") == "shared-model")
        let before = try fixture.store.layers.generatedPatch(fixture.target)
        try fixture.model("shared-model", content: "")
        #expect(throws: LanguageModelSettingsError.missingModel("shared-model")) { try fixture.store.setLanguageModel("shared-model") }
        #expect(try fixture.store.layers.generatedPatch(fixture.target) == before)
    }

    @Test func missingOrUnsafeSchemaNeverCreatesAConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.model()
        #expect(throws: LanguageModelSettingsError.missingSchema("missing")) { try fixture.store.setLanguageModel("wanxiang-lts-zh-hans", schemaID: "missing") }
        #expect(throws: LanguageModelSettingsError.missingSchema("../outside")) { try fixture.store.setLanguageModel("wanxiang-lts-zh-hans", schemaID: "../outside") }
        try FileManager.default.removeItem(at: fixture.paths.builtConfig("default"))
        #expect(throws: LanguageModelSettingsError.missingSchema(nil)) { try fixture.store.setLanguageModel("wanxiang-lts-zh-hans") }
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.generatedDir.path))
    }

    @Test func preservesSourceImportedAndGeneratedParametersAndOtherSettings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.model()
        try "schema:\n  schema_id: rime_ice\ngrammar:\n  collocation_max_length: 9\n".write(
            to: fixture.paths.sharedDataDir!.appendingPathComponent("rime_ice.schema.yaml"), atomically: true, encoding: .utf8)
        try fixture.store.layers.writeImported(fixture.target, yaml: "patch:\n  grammar/collocation_min_length: 4\n  translator/contextual_suggestions: true\n")
        try fixture.store.layers.setGenerated(fixture.target, keypath: "grammar/rear_penalty", value: -40)
        try fixture.store.layers.setGenerated(fixture.target, keypath: "menu/page_size", value: 7)
        try fixture.store.setLanguageModel("wanxiang-lts-zh-hans")
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "grammar/collocation_max_length") == nil)
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "grammar/collocation_min_length") == nil)
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "grammar/rear_penalty") == -40)
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "menu/page_size") == 7)
        #expect(try fixture.store.layers.importedPatch(fixture.target).contains { $0.key == "translator/contextual_suggestions" && $0.value == true })
    }

    @Test func respectsForeignCustomSettingsBeforeTheirAdoption() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.model()
        try "patch:\n  grammar/non_collocation_penalty: -55\n".write(to: fixture.store.layers.shimURL(fixture.target), atomically: true, encoding: .utf8)
        try fixture.store.setLanguageModel("wanxiang-lts-zh-hans")
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "grammar/non_collocation_penalty") == nil)
        #expect(try fixture.store.layers.importedPatch(fixture.target).contains { $0.key == "grammar/non_collocation_penalty" && $0.value == -55 })
    }

    @Test func emptySelectionChangesOnlyLanguage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.model()
        try fixture.store.setLanguageModel("wanxiang-lts-zh-hans")
        let before = try fixture.store.layers.generatedPatch(fixture.target).filter { $0.key != "grammar/language" }
        try fixture.store.setLanguageModel("")
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "grammar/language") == "")
        #expect(try fixture.store.layers.generatedPatch(fixture.target).filter { $0.key != "grammar/language" } == before)
    }

    @Test func resettingRemovesOwnedDefaultsButPreservesSubsequentUserEdits() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.model()
        try fixture.store.setLanguageModel("wanxiang-lts-zh-hans")
        try fixture.store.layers.setGenerated(fixture.target, keypath: "grammar/collocation_max_length", value: 8)
        try fixture.store.layers.setGenerated(fixture.target, keypath: "menu/page_size", value: 7)
        try fixture.store.resetLanguageModel()
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "grammar/language") == nil)
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "grammar/collocation_max_length") == 8)
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "grammar/collocation_min_length") == nil)
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "aime/_language_model_defaults") == nil)
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "menu/page_size") == 7)
    }

    @Test func switchingModelsRechecksNewImportedValuesInsteadOfKeepingOldDefaults() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.model("first")
        try fixture.model("second")
        try fixture.store.setLanguageModel("first")
        try fixture.store.layers.writeImported(fixture.target, yaml: "patch:\n  grammar/collocation_min_length: 3\n")
        try fixture.store.setLanguageModel("second")
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "grammar/language") == "second")
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "grammar/collocation_min_length") == nil)
        #expect(try fixture.store.layers.composedPatch(fixture.target).contains { $0.key == "grammar/collocation_min_length" && $0.value == 3 })
        try fixture.store.resetLanguageModel()
        #expect(try fixture.store.layers.generatedPatch(fixture.target).isEmpty)
    }

    @Test func reselectingReplacesOldAutomaticDefaultsEvenWhenRimeQuotesNumbers() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.model()
        // A prior version supplied -12; current defaults use -14.
        try fixture.store.layers.setGenerated(fixture.target, keypath: "grammar/collocation_penalty", value: -12)
        try fixture.store.layers.setGenerated(fixture.target, keypath: "aime/_language_model_defaults", value: .map([
            .init("grammar/collocation_penalty", -12),
        ]))
        try "grammar:\n  collocation_penalty: \"-12\"\n".write(
            to: fixture.paths.builtConfig(fixture.target.configID), atomically: true, encoding: .utf8)
        try fixture.store.setLanguageModel("wanxiang-lts-zh-hans")
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "grammar/collocation_penalty") == -14)
        try fixture.store.layers.setGenerated(fixture.target, keypath: "grammar/collocation_penalty", value: "-14")
        try fixture.store.resetLanguageModel()
        #expect(try fixture.store.layers.generatedPatch(fixture.target).isEmpty)
    }

    @Test func uninstallClearsDisabledAndUndeployedSourceImportedAndForeignReferences() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let name = "wanxiang-lts-zh-hans"
        try fixture.store.layers.writeImported(fixture.target, yaml: "patch:\n  grammar:\n    language: \(name)\n    collocation_max_length: 9\n")
        let disabledSource = ConfigTarget.schema("disabled_source")
        let disabledImported = ConfigTarget.schema("disabled_imported")
        let disabledForeign = ConfigTarget.schema("disabled_foreign")
        for target in [disabledSource, disabledImported, disabledForeign] {
            try "schema:\n  schema_id: \(target.customName)\n".write(
                to: fixture.paths.sharedDataDir!.appendingPathComponent("\(target.customName).schema.yaml"), atomically: true, encoding: .utf8)
        }
        try "schema:\n  schema_id: disabled_source\ngrammar:\n  language: \(name)\n".write(
            to: fixture.paths.sharedDataDir!.appendingPathComponent("disabled_source.schema.yaml"), atomically: true, encoding: .utf8)
        try fixture.store.layers.writeImported(disabledImported, yaml: "patch:\n  grammar/language: \(name)\n")
        try "patch:\n  grammar/language: \(name)\n".write(to: fixture.store.layers.shimURL(disabledForeign), atomically: true, encoding: .utf8)

        try fixture.store.disableLanguageModelReferences(named: name)

        for target in [fixture.target, disabledSource, disabledImported, disabledForeign] {
            #expect(fixture.store.layers.generatedValue(target, keypath: "grammar/language") == "")
        }
        #expect(fixture.store.pendingSchemas() == ["rime_ice"])
        #expect(try fixture.store.layers.importedPatch(fixture.target).last { $0.key == "grammar" }?.value["collocation_max_length"] == 9)
    }

    @Test func uninstallHonorsPendingReplacementsAndOnlyFallsBackToBuildForMissingLanguage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ids = ["pending_flat", "pending_nested", "explicit_empty", "explicit_null", "built_only"]
        let name = "wanxiang-lts-zh-hans"
        for id in ids {
            try "schema:\n  schema_id: \(id)\n".write(
                to: fixture.paths.sharedDataDir!.appendingPathComponent("\(id).schema.yaml"), atomically: true, encoding: .utf8)
            try "grammar:\n  language: \(name)\n".write(to: fixture.paths.builtConfig("\(id).schema"), atomically: true, encoding: .utf8)
        }
        try fixture.store.layers.setGenerated(.schema("pending_flat"), keypath: "grammar/language", value: "another-model")
        try fixture.store.layers.setGenerated(.schema("pending_nested"), keypath: "grammar", value: .map([.init("language", "another-model")]))
        try fixture.store.layers.setGenerated(.schema("explicit_empty"), keypath: "grammar/language", value: "")
        try fixture.store.layers.setGenerated(.schema("explicit_null"), keypath: "grammar/language", value: .null)
        let before = try ids.dropLast().map { try fixture.store.layers.generatedPatch(.schema($0)) }

        try fixture.store.disableLanguageModelReferences(named: name)

        #expect(try ids.dropLast().map { try fixture.store.layers.generatedPatch(.schema($0)) } == before)
        #expect(fixture.store.layers.generatedValue(.schema("built_only"), keypath: "grammar/language") == "")
        #expect(!FileManager.default.fileExists(atPath: fixture.store.layers.generatedURL(fixture.target).path))
    }

    @Test func selectionPreservesParametersInNestedGrammarReplacementAndResetRestoresItsLanguage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.model()
        try fixture.store.layers.setGenerated(fixture.target, keypath: "grammar/=", value: .map([
            .init("language", "previous-model"), .init("collocation_min_length", 4), .init("rear_penalty", -40),
        ]))
        try fixture.store.setLanguageModel("wanxiang-lts-zh-hans")
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "grammar/collocation_min_length") == nil)
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "grammar/rear_penalty") == nil)
        try fixture.store.resetLanguageModel()
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "grammar/language") == nil)
        #expect(fixture.store.layers.generatedValue(fixture.target, keypath: "grammar/=")?["language"] == "previous-model")
    }
}
