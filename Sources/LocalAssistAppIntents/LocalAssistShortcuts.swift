import AppIntents

public struct LocalAssistShortcuts: AppShortcutsProvider {
    public static let shortcutTileColor: ShortcutTileColor = .navy

    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureThoughtIntent(),
            phrases: [
                "Capture a thought with \(.applicationName)",
                "Start a capture in \(.applicationName)",
                "New voice note in \(.applicationName)",
            ],
            shortTitle: "Capture a Thought",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: LocalAssistSummaryIntent(),
            phrases: [
                "Summarize my notes with \(.applicationName)",
                "Summarize with \(.applicationName)",
                "Run \(.applicationName) on my notes",
                "Create tasks with \(.applicationName)",
                "Turn my notes into tasks with \(.applicationName)",
            ],
            shortTitle: "Summarize Notes",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: CreateReminderIntent(),
            phrases: [
                "Create a reminder with \(.applicationName)",
                "Remind me about my notes with \(.applicationName)",
                "Find my next task with \(.applicationName)",
            ],
            shortTitle: "Create Reminder",
            systemImageName: "bell.badge"
        )
        AppShortcut(
            intent: ShowRecentRunsIntent(),
            phrases: [
                "Show \(.applicationName) history",
                "Show recent runs in \(.applicationName)",
                "What did \(.applicationName) summarize recently",
            ],
            shortTitle: "Recent Runs",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}
