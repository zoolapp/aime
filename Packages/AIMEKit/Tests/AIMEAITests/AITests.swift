import Foundation
import Testing
@testable import AIMEAI
@testable import AIMECore

struct MockProvider: AIProvider {
    let id = "mock"
    let displayName = "Mock"
    let reply: String
    func availability() async -> AIAvailability { .available }
    func complete(instructions: String, prompt: String) async throws -> String { reply }
}

struct AITests {
    let catalog: SettingCatalog = {
        let json = """
        {"version":1,"groups":[{"id":"general","title":"g"}],"settings":[
          {"id":"menu.page_size","group":"general","title":"候选词个数","file":"default","keypath":"menu/page_size","type":"int","min":1,"max":10},
          {"id":"appearance.layout","group":"general","title":"布局","file":"frontend","keypath":"style/candidate_list_layout","type":"enum",
           "options":[{"value":"linear","title":"横排"},{"value":"stacked","title":"竖排"}]},
          {"id":"spelling.fuzzy.zh_z","group":"general","title":"zh=z","file":"schema","keypath":"speller/algebra","type":"bool","algebra":["derive/^zh/z/"]}
        ]}
        """
        return try! JSONDecoder().decode(SettingCatalog.self, from: Data(json.utf8))
    }()

    @Test func validatesProposedChanges() async throws {
        let reply = """
        好的，以下是修改：
        ```json
        {"changes":[{"id":"menu.page_size","value":7},{"id":"appearance.layout","value":"stacked"},
          {"id":"spelling.fuzzy.zh_z","value":"true"},{"id":"menu.page_size_typo","value":3},{"id":"appearance.layout","value":"diagonal"}],
         "explanation":"已调整"}
        ```
        """
        let assistant = ConfigAssistant(provider: MockProvider(reply: reply), catalog: catalog)
        let result = try await assistant.propose("候选 7 个，竖排，zh z 不分") { $0.id == "menu.page_size" ? 5 : nil }
        #expect(result.proposals.map(\.setting.id) == ["menu.page_size", "spelling.fuzzy.zh_z"])
        #expect(result.proposals[0].current == 5 && result.proposals[0].proposed == 7)
        #expect(result.proposals[1].proposed == true)
        #expect(result.rejected.count == 2)
        #expect(result.explanation == "已调整")
    }

    @Test func rejectsOutOfRangeAndGarbage() async throws {
        let assistant = ConfigAssistant(provider: MockProvider(reply: #"{"changes":[{"id":"menu.page_size","value":42}]}"#), catalog: catalog)
        let result = try await assistant.propose("x") { _ in nil }
        #expect(result.proposals.isEmpty && result.rejected.count == 1)
        let broken = ConfigAssistant(provider: MockProvider(reply: "抱歉我不知道"), catalog: catalog)
        await #expect(throws: AIError.self) { try await broken.propose("x") { _ in nil } }
    }

    @Test func extractsTermsWithLocalPinyin() async throws {
        let reply = #"[{"text":"智能体","note":"AI"},{"text":"DeepSeek","note":"品牌"},{"text":"小米SU7","note":"产品"},{"text":"智能体"},{"text":"已有词"}]"#
        let terms = try await VocabularyExtractor(provider: MockProvider(reply: reply)).extract(from: "…", excluding: ["已有词"])
        #expect(terms.map(\.text) == ["智能体", "DeepSeek", "小米SU7"])
        #expect(terms.map(\.code) == ["zhinengti", "deepseek", "xiaomisu7"])
    }

    @Test func pinyinCodesHandleUmlaut() {
        #expect(VocabularyExtractor.inputCode(for: "绿色") == "lvse")
        #expect(VocabularyExtractor.inputCode(for: "   ") == nil)
    }
}

struct PolishTests {
    @Test func parsesVariantsAndDropsDuplicates() async throws {
        let reply = "```json\n{\"polished\":\"我们明天开会。\",\"formal\":\"我们将于明日召开会议。\",\"concise\":\"我们明天开会。\"}\n```"
        let variants = try await TextPolisher(provider: MockProvider(reply: reply)).polish("我们明天开个会")
        #expect(variants == [.init(label: "润色", text: "我们明天开会。"), .init(label: "正式", text: "我们将于明日召开会议。")])
    }

    @Test func rejectsOversizedSelectionWithoutCallingTheModel() async {
        await #expect(throws: AIError.self) {
            try await TextPolisher(provider: MockProvider(reply: "{}")).polish(String(repeating: "字", count: 2001))
        }
    }

    @Test func featuresDecodeWithMissingKeys() throws {
        let features = try JSONDecoder().decode(AIMEFeatures.self, from: Data(#"{"usageStats":true}"#.utf8))
        #expect(features.usageStats && !features.aiPolish && !features.aiRemoteAllowed && features.aiProvider == "apple")
        #expect(features.aiExtraJSON.isEmpty)
    }
}

struct TextActionTests {
    @Test func translatesWithAlternativeAndBareFallback() async throws {
        let json = #"{"translation":"See you tomorrow.","alternative":"Talk to you tomorrow."}"#
        let variants = try await TextActionRunner(provider: MockProvider(reply: json)).run(.translate, on: "明天见")
        #expect(variants.map(\.text) == ["See you tomorrow.", "Talk to you tomorrow."])
        let bare = try await TextActionRunner(provider: MockProvider(reply: "“明天见。”")).run(.translate, on: "See you tomorrow.")
        #expect(bare == [.init(label: "译文", text: "明天见。")])
    }

    @Test func customPromptReturnsCleanText() async throws {
        let reply = "```\n开会改到周三下午三点。\n```"
        let action = TextAction.custom(name: "更口语", prompt: "把这段话改得更口语")
        let variants = try await TextActionRunner(provider: MockProvider(reply: reply)).run(action, on: "会议时间调整为周三 15:00")
        #expect(variants == [.init(label: "更口语", text: "开会改到周三下午三点。")])
        #expect(action.title == "更口语" && TextAction.polish.title == "润色")
    }

    @Test func emptyAndOversizedInputsNeverReachTheModel() async throws {
        let runner = TextActionRunner(provider: MockProvider(reply: "x"))
        let empty = try await runner.run(.polish, on: "   ")
        #expect(empty.isEmpty)
        await #expect(throws: AIError.self) { try await runner.run(.translate, on: String(repeating: "字", count: 2001)) }
    }
}

struct CredentialAndErrorTests {
    @Test func credentialsLiveInAnOwnerOnlyFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aime-cred-\(UUID().uuidString)/credentials.json")
        let store = CredentialStore(account: "openai-compatible", fileURL: url)
        #expect(store.read() == nil)
        #expect(store.write("sk-test"))
        #expect(store.read() == "sk-test")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(CredentialStore(account: "other", fileURL: url).read() == nil)   // accounts are separate
        #expect(store.write(nil))
        #expect(store.read() == nil)
    }

    @Test func httpErrorsAreExplained() {
        #expect(OpenAICompatibleProvider.explain(status: 401, body: "").contains("API Key"))
        #expect(OpenAICompatibleProvider.explain(status: 404, body: "").contains("/v1"))
        #expect(OpenAICompatibleProvider.explain(status: 524, body: "").contains("超时"))
        #expect(OpenAICompatibleProvider.explain(status: 429, body: "").contains("额度"))
        #expect(OpenAICompatibleProvider.explain(URLError(.timedOut), host: "api.example.com") == "连接 api.example.com 超时")
        #expect(AIError.http(524, OpenAICompatibleProvider.explain(status: 524, body: "")).description.hasPrefix("HTTP 524："))
    }

    @Test func extraFieldsParseOnlyJSONObjects() {
        #expect(OpenAICompatibleProvider.extraFields(from: "").isEmpty)
        #expect(OpenAICompatibleProvider.extraFields(from: "  ").isEmpty)
        #expect(OpenAICompatibleProvider.extraFields(from: "not json").isEmpty)
        #expect(OpenAICompatibleProvider.extraFields(from: "[1,2]").isEmpty)
        let fields = OpenAICompatibleProvider.extraFields(from: #"{"enable_thinking":false,"n":1}"#)
        #expect(fields["enable_thinking"] as? Bool == false && fields["n"] as? Int == 1)
    }

    @Test func missingKeyFailsBeforeAnyRequest() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aime-cred-\(UUID().uuidString)/credentials.json")
        let provider = OpenAICompatibleProvider(baseURL: URL(string: "https://example.invalid/v1")!, model: "m",
                                                credentials: CredentialStore(account: "none", fileURL: url))
        await #expect(throws: AIError.missingAPIKey) { try await provider.verify() }
    }
}
