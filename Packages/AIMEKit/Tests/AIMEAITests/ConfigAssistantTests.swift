import Foundation
import Testing
@testable import AIMEAI
@testable import AIMECore

struct ConfigAssistantTests {
    private func catalog(type: String = "int", bounds: String = "") throws -> SettingCatalog {
        let json = """
        {"version":1,"groups":[],"settings":[
          {"id":"number","group":"general","title":"数值","file":"default","keypath":"number","type":"\(type)"\(bounds)}
        ]}
        """
        return try JSONDecoder().decode(SettingCatalog.self, from: Data(json.utf8))
    }

    private func propose(_ value: String, type: String = "int", bounds: String = "") async throws -> ConfigAssistant.Result {
        let reply = """
        {"changes":[{"id":"number","value":\(value)}]}
        """
        let assistant = ConfigAssistant(provider: MockProvider(reply: reply), catalog: try catalog(type: type, bounds: bounds))
        return try await assistant.propose("调整数值") { _ in nil }
    }

    @Test(arguments: [#""NaN""#, #""+Inf""#, #""-Inf""#, #""Infinity""#, #""-Infinity""#, "1e30", "-1e30", #""1e30""#])
    func rejectsNumbersThatCannotBecomeIntegers(_ value: String) async throws {
        let result = try await propose(value)
        #expect(result.proposals.isEmpty)
        #expect(result.rejected.count == 1)
    }

    @Test(arguments: [#""NaN""#, #""+Inf""#, #""-Inf""#])
    func rejectsNonFiniteDoubles(_ value: String) async throws {
        let result = try await propose(value, type: "double")
        #expect(result.proposals.isEmpty)
        #expect(result.rejected.count == 1)
    }

    @Test(arguments: ["-1", "0", "0.9", "10.1", "11"])
    func rejectsOutOfRangeNumbers(_ value: String) async throws {
        let result = try await propose(value, bounds: #", "min":1,"max":10"#)
        #expect(result.proposals.isEmpty)
        #expect(result.rejected.count == 1)
    }

    @Test(arguments: [("1", 1), ("10", 10), ("7", 7), (#""7""#, 7), ("1.5", 2), ("9.5", 10)])
    func acceptsBoundariesAndValidNumbers(_ value: String, expected: Int) async throws {
        let result = try await propose(value, bounds: #", "min":1,"max":10"#)
        #expect(result.proposals.map(\.proposed) == [.int(expected)])
        #expect(result.rejected.isEmpty)
    }

    @Test(arguments: ["1.2", "9.8"])
    func rechecksBoundsAfterRounding(_ value: String) async throws {
        let result = try await propose(value, bounds: #", "min":1.2,"max":9.8"#)
        #expect(result.proposals.isEmpty)
        #expect(result.rejected.count == 1)
    }

    @Test func acceptsNegativeValuesWhenInRange() async throws {
        let result = try await propose("-2.5", bounds: #", "min":-10,"max":0"#)
        #expect(result.proposals.map(\.proposed) == [.int(-3)])
        #expect(result.rejected.isEmpty)
    }

    @Test func preservesValidDouble() async throws {
        let result = try await propose("1.25", type: "double", bounds: #", "min":1,"max":2"#)
        #expect(result.proposals.map(\.proposed) == [.double(1.25)])
        #expect(result.rejected.isEmpty)
    }

    @Test func mergesIdenticalProposals() async throws {
        let reply = #"{"changes":[{"id":"number","value":7},{"id":"number","value":7},{"id":"number","value":7}]}"#
        let assistant = ConfigAssistant(provider: MockProvider(reply: reply), catalog: try catalog())
        let result = try await assistant.propose("调整数值") { _ in .int(5) }
        #expect(result.proposals.map(\.id) == ["number"])
        #expect(result.proposals.map(\.proposed) == [.int(7)])
        #expect(result.proposals.first?.current == .int(5))
        #expect(result.rejected.isEmpty)
    }

    @Test(arguments: ["8", #""NaN""#])
    func rejectsAllConflictingProposals(_ other: String) async throws {
        let reply = """
        {"changes":[{"id":"number","value":7},{"id":"number","value":\(other)},{"id":"number","value":7}]}
        """
        let assistant = ConfigAssistant(provider: MockProvider(reply: reply), catalog: try catalog())
        // A no-op first value must still participate in conflict detection.
        let result = try await assistant.propose("调整数值") { _ in .int(7) }
        #expect(result.proposals.isEmpty)
        #expect(result.rejected == ["number：同一设置存在不同取值的重复提案，已全部拒绝"])
    }

    @Test func preservesOrderOfUnrelatedProposals() async throws {
        let reply = """
        {"changes":[{"id":"menu.page_size","value":7},{"id":"appearance.layout","value":"stacked"},
          {"id":"menu.page_size","value":7},{"id":"spelling.fuzzy.zh_z","value":true}]}
        """
        let assistant = ConfigAssistant(provider: MockProvider(reply: reply), catalog: AITests().catalog)
        let result = try await assistant.propose("调整配置") { _ in nil }
        #expect(result.proposals.map(\.id) == ["menu.page_size", "appearance.layout", "spelling.fuzzy.zh_z"])
        #expect(result.rejected.isEmpty)
    }
}
