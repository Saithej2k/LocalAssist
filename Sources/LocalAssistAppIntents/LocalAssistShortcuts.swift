import AppIntents

@available(macOS 13.0, iOS 16.0, *)
public struct LocalAssistShortcuts: AppShortcutsProvider {
    public static let shortcutTileColor: ShortcutTileColor = .navy

    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LocalAssistSummaryIntent(),
            phrases: [
                "Summarize with \(.applicationName)",
                "Run \(.applicationName) on my notes",
                "Create tasks with \(.applicationName)",
            ],
            shortTitle: "Summarize Notes",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: CreateReminderDraftIntent(),
            phrases: [
                "Draft a reminder with \(.applicationName)",
                "Find my next task with \(.applicationName)",
            ],
            shortTitle: "Draft Reminder",
            systemImageName: "bell.badge"
        )
        AppShortcut(
            intent: ShowRecentRunsIntent(),
            phrases: [
                "Show \(.applicationName) history",
                "Show recent runs in \(.applicationName)",
            ],
            shortTitle: "Recent Runs",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}
