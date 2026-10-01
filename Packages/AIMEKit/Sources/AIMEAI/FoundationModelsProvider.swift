public import Foundation
import FoundationModels

/// Apple's on-device model (Apple Intelligence). Nothing leaves the Mac.
public struct FoundationModelsProvider: AIProvider {
    public let id = "apple"
    public let displayName = "Apple 端侧模型"

    public init() {}

    public func availability() async -> AIAvailability {
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
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt).content
    }
}
