import Foundation
import FoundationModels
import LocalAssistCore
import OSLog

public struct FoundationModelsLanguageModelClient: LanguageModelClient {
    public init() {}

    public func availability() async -> ModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case let .unavailable(reason):
            return .unavailable(reason: String(describing: reason))
        @unknown default:
            return .unavailable(reason: "Unknown Foundation Models availability state.")
        }
    }

    public func generateResponse(for prompt: String) async throws -> String {
        let signposter = OSSignposter(subsystem: "com.saithej.localassist", category: "FoundationModels")
        let state = signposter.beginInterval("LanguageModelSession.respond")
        defer {
            signposter.endInterval("LanguageModelSession.respond", state)
        }

        try Task.checkCancellation()
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt)
        try Task.checkCancellation()
        return response.content
    }

    public func streamResponse(for prompt: String) -> AsyncThrowingStream<PartialGeneration, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let signposter = OSSignposter(subsystem: "com.saithej.localassist", category: "FoundationModels")
                let state = signposter.beginInterval("LanguageModelSession.streamResponse")
                defer {
                    signposter.endInterval("LanguageModelSession.streamResponse", state)
                }

                do {
                    try Task.checkCancellation()
                    let session = LanguageModelSession()
                    var latestText = ""
                    var emittedSnapshot = false

                    for try await snapshot in session.streamResponse(to: prompt) {
                        try Task.checkCancellation()
                        latestText = snapshot.content
                        emittedSnapshot = true
                        continuation.yield(PartialGeneration(text: latestText, isComplete: false))
                    }

                    if emittedSnapshot {
                        continuation.yield(PartialGeneration(text: latestText, isComplete: true))
                    } else {
                        let response = try await session.respond(to: prompt)
                        try Task.checkCancellation()
                        continuation.yield(PartialGeneration(text: response.content, isComplete: true))
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

public enum LocalAssistLiveFactory {
    public static func makeService() -> LocalAssistService {
        LocalAssistService(primaryModel: FoundationModelsLanguageModelClient())
    }
}
