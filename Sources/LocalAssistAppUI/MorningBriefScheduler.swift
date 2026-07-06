import Foundation
import LocalAssistCore
#if canImport(UserNotifications)
    import UserNotifications
#endif

/// Schedules the next-morning local notification that gives the app its daily
/// moment: "3 due today · 2 captured yesterday".
///
/// Local notification content is fixed at schedule time, so instead of a
/// repeating trigger this schedules a single notification for the next
/// morning and re-computes it whenever history changes or the app opens.
/// Everything stays on device — no push, no server.
@MainActor
public final class MorningBriefScheduler: ObservableObject {
    public static let notificationIdentifier = "localassist.morning-brief"
    private static let enabledDefaultsKey = "localassist.morningBrief.enabled"

    @Published public private(set) var isEnabled: Bool

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let briefHour: Int

    public init(
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        briefHour: Int = 8
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.briefHour = briefHour
        isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    /// Enabling requests notification permission; returns whether the brief
    /// ended up enabled (false when the user denied access).
    @discardableResult
    public func setEnabled(_ enabled: Bool, history: [AssistantRun]) async -> Bool {
        guard enabled else {
            isEnabled = false
            defaults.set(false, forKey: Self.enabledDefaultsKey)
            cancelPending()
            return false
        }

        #if canImport(UserNotifications)
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            isEnabled = granted
            defaults.set(granted, forKey: Self.enabledDefaultsKey)
            if granted {
                await refresh(history: history)
            }
            return granted
        #else
            return false
        #endif
    }

    /// Recomputes and reschedules tomorrow morning's notification from the
    /// latest history. Call after each recorded run and on app foreground.
    public func refresh(history: [AssistantRun], now: Date = Date()) async {
        guard isEnabled else {
            return
        }

        #if canImport(UserNotifications)
            cancelPending()

            guard let fireDate = nextMorning(after: now) else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Your morning brief"
            content.body = Self.briefBody(history: history, briefDay: fireDate, calendar: calendar)
            content.sound = .default

            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fireDate
            )
            let request = UNNotificationRequest(
                identifier: Self.notificationIdentifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await UNUserNotificationCenter.current().add(request)
        #endif
    }

    private func cancelPending() {
        #if canImport(UserNotifications)
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])
        #endif
    }

    private func nextMorning(after now: Date) -> Date? {
        guard let todayBrief = calendar.date(bySettingHour: briefHour, minute: 30, second: 0, of: now) else {
            return nil
        }
        if todayBrief > now {
            return todayBrief
        }
        return calendar.date(byAdding: .day, value: 1, to: todayBrief)
    }

    /// Pure so the copy is unit-testable without UserNotifications.
    public nonisolated static func briefBody(
        history: [AssistantRun],
        briefDay: Date,
        calendar: Calendar = .current
    ) -> String {
        var dueCount = 0
        var doneCount = 0
        for run in history {
            for task in run.summary.tasks {
                guard let dueDate = task.dueDate,
                      calendar.isDate(dueDate, inSameDayAs: briefDay)
                else {
                    continue
                }
                if run.isCompleted(task) {
                    doneCount += 1
                } else {
                    dueCount += 1
                }
            }
        }

        let capturedYesterday = history.filter { run in
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: briefDay) else {
                return false
            }
            return calendar.isDate(run.summary.generatedAt, inSameDayAs: yesterday)
        }.count

        let doneSuffix = doneCount > 0 ? " \(doneCount) already done." : ""
        switch (dueCount, capturedYesterday) {
        case (0, 0) where doneCount == 0:
            return "A clear morning. Capture a thought to plan your day."
        case (0, 0):
            return "Everything due today is done. Nice work."
        case (_, 0):
            return "\(dueCount) task\(dueCount == 1 ? "" : "s") due today.\(doneSuffix) Tap to review."
        case (0, _):
            return "\(capturedYesterday) capture\(capturedYesterday == 1 ? "" : "s") from yesterday to review.\(doneSuffix)"
        default:
            return "\(dueCount) due today · \(capturedYesterday) captured yesterday.\(doneSuffix)"
        }
    }
}
