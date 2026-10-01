public import Foundation

/// A text-in / text-out language model backend.
///
/// Privacy contract (see docs/privacy.md): providers only ever receive text the user
/// explicitly typed into the assistant or pasted for extraction, plus the public
/// settings catalog. Nothing from live typing or learned word frequencies is passed in —
/// this module has no dependency on the engine and cannot reach that data.
public protocol AIProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// True when the backend can serve requests right now.
    func availability() async -> AIAvailability
    func complete(instructions: String, prompt: String) async throws -> String
}

public enum AIAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }
}

public enum AIError: Error, Equatable, CustomStringConvertible {
    case unavailable(String)
    case missingAPIKey
    case badResponse(String)
    case http(Int, String)

    public var description: String {
        switch self {
        case let .unavailable(reason): "AI 不可用：\(reason)"
        case .missingAPIKey: "尚未配置 API Key"
        case let .badResponse(detail): "模型返回无法解析：\(detail)"
        case let .http(code, body): "HTTP \(code)：\(body.prefix(200))"
        }
    }
}

/// Extracts the first top-level JSON object or array from a model reply
/// (models like to wrap JSON in prose or code fences).
enum JSONExtractor {
    static func firstJSON(in text: String) -> Data? {
        let scalars = Array(text)
        guard let start = scalars.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let open = scalars[start], close: Character = open == "{" ? "}" : "]"
        var depth = 0, inString = false, escaped = false
        for index in start..<scalars.count {
            let char = scalars[index]
            if inString {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { inString = false }
                continue
            }
            if char == "\"" { inString = true }
            else if char == open { depth += 1 }
            else if char == close {
                depth -= 1
                if depth == 0 { return String(scalars[start...index]).data(using: .utf8) }
            }
        }
        return nil
    }
}
