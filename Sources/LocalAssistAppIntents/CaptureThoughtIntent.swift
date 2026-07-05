import AppIntents
import Foundation
import LocalAssistCore

/// "Capture a thought" from Siri, Spotlight, or the Lock Screen widget:
/// opens the app straight into a live voice capture. Microphone recording
/// requires the app in the foreground, so this intent opens the app rather
/// than running headless.
public struct CaptureThoughtIntent: AppIntent {
    public static let title: LocalizedStringResource = "Capture a Thought"
    public static let description = IntentDescription(
        "Open LocalAssist and start a private, on-device voice capture immediately.",
        categoryName: "Capture"
    )

    public static let openAppWhenRun = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        // Give the UI a beat to attach its listener on cold launch before
        // requesting the capture.
        try? await Task.sleep(nanoseconds: 350_000_000)
        NotificationCenter.default.post(name: .localAssistCaptureRequested, object: nil)
        return .result()
    }
}
