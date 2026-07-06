import Foundation
import LocalAssistCore
#if canImport(WidgetKit)
    import WidgetKit
#endif

/// Hand-off mailbox between the share extension and the app: the extension
/// appends shared text into app-group defaults; the app drains it into the
/// capture box on next foreground. Plain UserDefaults is enough — the data is
/// a single pending string and never leaves the device.
public enum PendingCaptureInbox {
    public static let key = "localassist.pendingCaptureText"

    public static func drain() -> String? {
        guard let defaults = UserDefaults(suiteName: RunHistoryStore.appGroupIdentifier),
              let text = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return nil
        }
        defaults.removeObject(forKey: key)
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
