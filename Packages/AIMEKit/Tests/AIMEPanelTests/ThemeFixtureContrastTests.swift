import AIMECore
import Foundation
import Testing
@testable import AIMEPanel

/// The website shows each theme's contrast with its own JavaScript port; both must agree
/// with what the candidate panel computes (fixture values from scripts/export-themes.py).
@Suite struct ThemeFixtureContrastTests {
    struct Case: Decodable { let id: String; let d: String; let min_contrast: Double }

    @Test func panelContrastMatchesTheFixtures() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../AIMECoreTests/Fixtures/theme-v1/valid.json").standardizedFileURL
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        for item in cases {
            let package = try ThemePackage.decode(payload: item.d).package
            let frontend = ConfigValue.map([
                .init("style", .map([.init("color_scheme", .string(package.id))])),
                .init("preset_color_schemes", .map([.init(package.id, package.schemeValue)])),
            ])
            let theme = PanelTheme(frontend: frontend, dark: false)
            #expect(abs(theme.minimumTextContrast - item.min_contrast) <= 0.01, "\(item.id): \(theme.minimumTextContrast)")
        }
    }
}
