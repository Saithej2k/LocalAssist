import Foundation
import LocalAssistCore
#if canImport(WidgetKit)
    import WidgetKit
#endif

/// Hand-off mailbox between the share extension and the app: the extension
/// appends shared text into a plain file in the app-group container; the app
/// drains it into the capture box on next foreground. A file, not group
/// UserDefaults — touching a group preferences suite makes cfprefsd log a
/// kCFPreferencesAnyUser complaint on device even when the group provisions.
public enum PendingCaptureInbox {
    public static func drain() -> String? {
        guard let fileURL = RunHistoryStore.pendingCaptureFileURL,
              let text = (try? String(contentsOf: fileURL, encoding: .utf8))?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return nil
        }
        try? FileManager.default.removeItem(at: fileURL)
        return text
    }
}

/// Widget refresh hook, kept beside the store so every history write site can
/// call it without importing WidgetKit directly.
public enum LocalAssistWidgetRefresher {
    public static func refresh() {
        #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
