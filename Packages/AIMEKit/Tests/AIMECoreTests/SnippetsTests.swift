import Foundation
import Testing
@testable import AIMECore

struct SnippetsTests {
    @Test func savesOwnerOnlyAndFeedsTheMenu() throws {
        let paths = AIMEPaths(userDataDir: FileManager.default.temporaryDirectory.appendingPathComponent("aime-snip-\(UUID().uuidString)"))
        #expect(Snippets.load(paths).categories.isEmpty)
        var snippets = Snippets()
        snippets.categories = [.init(name: "手机号", items: [" 138 0000 0000 ", ""]), .init(name: "", items: ["x"])]
        try snippets.save(paths)
        let loaded = Snippets.load(paths)
        #expect(loaded == snippets)
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.aimeDir.appendingPathComponent("snippets.json").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        // Blank items are dropped and an unnamed category still gets a tab title.
        #expect(loaded.menuCategories.map(\.items) == [["138 0000 0000"], ["x"]])
        #expect(loaded.menuCategories.map(\.title) == ["手机号", "未命名"])
    }
}
