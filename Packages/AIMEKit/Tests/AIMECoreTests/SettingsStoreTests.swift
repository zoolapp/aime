import Foundation
import Testing
@testable import AIMECore

struct SettingsStoreTests {
    let paths: AIMEPaths
    let catalog: SettingCatalog

    init() throws {
        paths = AIMEPaths(userDataDir: FileManager.default.temporaryDirectory.appendingPathComponent("aime-store-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: paths.stagingDir, withIntermediateDirectories: true)
        try """
        schema_list:
          - schema: rime_ice
        menu:
          page_size: 9
        """.write(to: paths.builtConfig("default"), atomically: true, encoding: .utf8)
        try """
        speller:
          algebra:
            - erase/^xx$/
            - abbrev/^([a-z]).+$/$1/
        """.write(to: paths.builtConfig("rime_ice.schema"), atomically: true, encoding: .utf8)
        let json = """
        {"version":1,"groups":[{"id":"general","title":"输入习惯"}],"settings":[
          {"id":"menu.page_size","group":"general","title":"候选词个数","file":"default","keypath":"menu/page_size","type":"int","min":1,"max":10,"default":5},
          {"id":"spelling.fuzzy.l_n","group":"spelling","title":"l ⇄ n","file":"schema","keypath":"speller/algebra","type":"bool","algebra":["derive/^l/n/","derive/^n/l/"]}
        ]}
        """
        catalog = try JSONDecoder().decode(SettingCatalog.self, from: Data(json.utf8))
    }

    @Test func readsDeployedValuesAndSchemas() throws {
        let store = SettingsStore(paths: paths, catalog: catalog)
        #expect(store.enabledSchemas() == ["rime_ice"])
        #expect(store.value(for: catalog.setting("menu.page_size")!) == 9)
        #expect(store.value(for: catalog.setting("spelling.fuzzy.l_n")!) == false)
    }

    @Test func writesScalarIntoGeneratedLayer() throws {
        let store = SettingsStore(paths: paths, catalog: catalog)
        let setting = catalog.setting("menu.page_size")!
        try store.set(5, for: setting)
        #expect(store.value(for: setting) == 5)
        #expect(store.isCustomized(setting))
        #expect(throws: SettingsStore.WriteError.self) { try store.set(42, for: setting) }
        try store.reset(setting)
        #expect(store.value(for: setting) == 9)
    }

    @Test func togglesAlgebraRulesBeforeAbbreviations() throws {
        let store = SettingsStore(paths: paths, catalog: catalog)
        let fuzzy = catalog.setting("spelling.fuzzy.l_n")!
        try store.set(true, for: fuzzy)
        #expect(store.algebra(target: .schema("rime_ice")) == ["erase/^xx$/", "derive/^l/n/", "derive/^n/l/", "abbrev/^([a-z]).+$/$1/"])
        #expect(store.value(for: fuzzy) == true)
        try store.set(false, for: fuzzy)
        #expect(store.algebra(target: .schema("rime_ice")) == ["erase/^xx$/", "abbrev/^([a-z]).+$/$1/"])
    }

    @Test func roundTripsYAMLWithQuoting() throws {
        let value: ConfigValue = .map([
            .init("patch", .map([
                .init("menu/page_size", 5),
                .init("style/font_face", "PingFang SC"),
                .init("punctuator/half_shape/,", "，"),
                .init("key", "true"),
                .init("list", ["derive/^([zcs])h/$1/", "0x1234"]),
            ])),
        ])
        let yaml = try value.yamlString()
        #expect(try ConfigValue.parse(yaml: yaml) == value)
    }
}
