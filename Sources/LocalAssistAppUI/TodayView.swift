import LocalAssistCore
import SwiftUI

struct TodayView: View {
    struct TodayItem: Identifiable {
        var runID: String
        var task: TaskSuggestion
        var isDone: Bool

        var id: String { "\(runID)-\(task.id)" }
    }

    var currentRun: AssistantRun?
    var history: [AssistantRun]
    var onToggle: (String, TaskSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Today", symbol: "sun.max.fill")

            HStack(spacing: 10) {
                TodayMetric(title: "Due today", value: "\(dueToday.filter { !$0.isDone }.count)", tint: LocalAssistColors.danger)
                TodayMetric(title: "Done", value: "\(allItems.filter(\.isDone).count)", tint: LocalAssistColors.success)
                TodayMetric(title: "Captures", value: "\(allRuns.count)", tint: LocalAssistColors.accent)
            }

            if nextActions.isEmpty {
                Label("No actions yet. Capture a note or dictate a thought to build today’s list.", systemImage: "tray")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(nextActions.prefix(5)) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                onToggle(item.runID, item.task)
                            } label: {
                                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(item.isDone ? LocalAssistColors.success : .secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.isDone ? "Mark \(item.task.title) as not done" : "Mark \(item.task.title) as done")

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.task.title)
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                    .strikethrough(item.isDone)
                                    .foregroundStyle(item.isDone ? .secondary : .primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(todayDetail(for: item.task))
                                    .font(.system(.caption, design: .rounded, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            PriorityDot(priority: item.task.priority)
                                .padding(.top, 6)
                        }
                    }
                }
            }
        }
        .panel()
    }

    /// History already contains the current run after it is recorded; only
    /// prepend it when it has not been persisted yet.
    private var allRuns: [AssistantRun] {
        var runs = history
        if let currentRun, !runs.contains(where: { $0.id == currentRun.id }) {
            runs.insert(currentRun, at: 0)
        }
        return runs
    }

    private var allItems: [TodayItem] {
        allRuns.flatMap { run in
            run.summary.tasks.map { task in
                TodayItem(runID: run.id, task: task, isDone: run.isCompleted(task))
            }
        }
    }

    private var dueToday: [TodayItem] {
        allItems.filter { item in
            guard let dueDate = item.task.dueDate else {
                return false
            }
            return Calendar.current.isDateInToday(dueDate)
        }
    }

    private var nextActions: [TodayItem] {
        let todayIDs = Set(dueToday.map(\.id))
        let prioritized = allItems.filter { item in
            todayIDs.contains(item.id) || item.task.priority == .high || item.task.action != .none
        }
        // Open tasks first, done tasks sink to the bottom of the list.
        return Array(prioritized.sorted { !$0.isDone && $1.isDone }.prefix(6))
    }

    private func todayDetail(for suggestion: TaskSuggestion) -> String {
        let action = suggestion.action.displayTitle
        if let dueDate = suggestion.iso8601DueDate {
            return "\(action) · \(dueDate)"
        }
        if let dueHint = suggestion.dueHint {
            return "\(action) · \(dueHint)"
        }
        return action
    }
}

struct TodayMetric: View {
    var title: String
    var value: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
