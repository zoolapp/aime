public import Foundation
import FoundationModels

/// Apple's on-device model (Apple Intelligence). Nothing leaves the Mac.
/// FoundationModels ships with macOS 26; on older systems the provider reports itself unavailable.
public struct FoundationModelsProvider: AIProvider {
    public let id = "apple"
    public let displayName = "Apple 端侧模型"

    public init() {}

    public func availability() async -> AIAvailability {
        guard #available(macOS 26, *) else {
            return .unavailable(reason: "Apple 端侧模型需要 macOS 26 或更高版本，可改用自备接口")
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case let .unavailable(reason):
            let text: String = switch reason {
            case .deviceNotEligible: "此设备不支持 Apple Intelligence"
            case .appleIntelligenceNotEnabled: "请在系统设置中开启 Apple Intelligence"
            case .modelNotReady: "端侧模型尚未下载完成"
            @unknown default: "端侧模型不可用"
            }
            return .unavailable(reason: text)
        }
    }

    public func complete(instructions: String, prompt: String) async throws -> String {
        guard case .available = await availability() else {
            throw AIError.unavailable("Apple Intelligence")
        }
        guard #available(macOS 26, *) else { throw AIError.unavailable("Apple Intelligence") }
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt).content
    }
}
