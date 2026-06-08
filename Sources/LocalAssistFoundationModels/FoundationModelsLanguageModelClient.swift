import Foundation
import FoundationModels
import LocalAssistCore

public struct FoundationModelsLanguageModelClient: LanguageModelClient {
    public init() {}

    public func availability() async -> ModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: String(describing: reason))
        @unknown default:
            return .unavailable(reason: "Unknown Foundation Models availability state.")
        }
    }

    public func generateResponse(for prompt: String) async throws -> String {
        try Task.checkCancellation()
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt)
        try Task.checkCancellation()
        return response.content
    }
}

public enum LocalAssistLiveFactory {
    public static func makeService() -> LocalAssistService {
        LocalAssistService(primaryModel: FoundationModelsLanguageModelClient())
    }
}
