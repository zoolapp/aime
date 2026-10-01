import Foundation
import Testing
@testable import AIMECore

struct AppRecommendationsTests {
    let shipped: AppRecommendations = {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try! Data(contentsOf: repo.appendingPathComponent("SharedSupport/aime/app-recommendations.json"))
        return try! JSONDecoder().decode(AppRecommendations.self, from: data)
    }()

    @Test func matchesByBundlePrefixAndCategoryInRuleOrder() {
        let apps: [AppRecommendations.InstalledApp] = [
            .init(bundleID: "com.mitchellh.ghostty", name: "Ghostty"),
            .init(bundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA", category: "public.app-category.developer-tools"),
            .init(bundleID: "org.vim.MacVim", name: "MacVim"),
            .init(bundleID: "com.postmanlabs.mac", name: "Postman", category: "public.app-category.developer-tools"),
            .init(bundleID: "com.tencent.xinWeChat", name: "WeChat", category: "public.app-category.social-networking"),
        ]
        let suggestions = shipped.suggestions(for: apps, existing: [])
        let byID = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.id, $0) })
        #expect(byID["com.mitchellh.ghostty"]?.rule.id == "terminal")
        #expect(byID["com.jetbrains.intellij"]?.rule.id == "editor")            // prefix beats the broad category rule
        #expect(byID["org.vim.MacVim"]?.option.vimMode == true)
        #expect(byID["com.postmanlabs.mac"]?.selected == false)                 // category-only match: opt-in
        #expect(byID["com.tencent.xinWeChat"]?.option.initialMode == .chinese)   // chat apps open in 中文
        #expect(byID["com.mitchellh.ghostty"]?.option.initialMode == .english)
        #expect(byID["com.apple.Spotlight"]?.rule.id == "launcher")             // system service without an app bundle
        // AI apps of 2024–2025: coding tools start in English, assistants in Chinese.
        let more = shipped.suggestions(for: [
            .init(bundleID: "com.trae.app", name: "Trae", category: "public.app-category.developer-tools"),
            .init(bundleID: "com.openai.codex", name: "ChatGPT", category: "public.app-category.developer-tools"),
            .init(bundleID: "com.bytedance.douyin.desktop", name: "抖音", category: "public.app-category.developer-tools"),
            .init(bundleID: "md.obsidian", name: "Obsidian"),
        ], existing: [])
        let moreByID = Dictionary(uniqueKeysWithValues: more.map { ($0.id, $0) })
        #expect(moreByID["com.trae.app"]?.option.initialMode == .english)
        #expect(moreByID["com.openai.codex"]?.rule.id == "ai" && moreByID["com.openai.codex"]?.option.initialMode == .chinese)
        #expect(moreByID["com.bytedance.douyin.desktop"]?.rule.id == "content")   // named rule beats its odd category
        #expect(moreByID["md.obsidian"]?.option.initialMode == .chinese)
        // The recommendation is only the starting value: the user's choice is what gets applied.
        var wechat = byID["com.tencent.xinWeChat"]!
        wechat.initialMode = .english
        #expect(wechat.option.initialMode == .english)
    }

    @Test func leavesConfiguredAppsAlone() {
        let apps = [AppRecommendations.InstalledApp(bundleID: "com.apple.Terminal", name: "Terminal")]
        let suggestions = shipped.suggestions(for: apps, existing: ["com.apple.Terminal", "com.apple.Spotlight"])
        #expect(suggestions.isEmpty)
    }
}
