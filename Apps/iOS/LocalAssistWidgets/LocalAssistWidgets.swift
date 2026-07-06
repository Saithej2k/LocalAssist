import LocalAssistCore
import SwiftUI
import WidgetKit

// Two widgets, both fully local:
// - Capture: one tap deep-links into a live voice capture.
// - Due today: reads shared history from the app group and surfaces itself
//   in the Smart Stack on mornings with open tasks.

// MARK: - Capture widget

struct CaptureEntry: TimelineEntry {
    let date: Date
}

struct CaptureProvider: TimelineProvider {
    func placeholder(in _: Context) -> CaptureEntry {
        CaptureEntry(date: .now)
    }

    func getSnapshot(in _: Context, completion: @escaping (CaptureEntry) -> Void) {
        completion(CaptureEntry(date: .now))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<CaptureEntry>) -> Void) {
        completion(Timeline(entries: [CaptureEntry(date: .now)], policy: .never))
    }
}

struct CaptureWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(URL(string: "localassist://capture"))
            .containerBackground(for: .widget) {
                Color.clear
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill")
                    .font(.title3)
            }
            .accessibilityLabel("Capture a thought")

        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Capture a thought")
                        .font(.headline)
                    Text("Private · on device")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

        default:
            VStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.tint)
                Text("Capture a thought")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                Label("On device", systemImage: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CaptureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LocalAssistCaptureWidget", provider: CaptureProvider()) { _ in
            CaptureWidgetView()
        }
        .configurationDisplayName("Capture a Thought")
        .description("One tap starts a private voice capture. Everything stays on your phone.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Due today widget

struct DueTodayEntry: TimelineEntry {
    let date: Date
    let openCount: Int
    let doneCount: Int
    let topTitles: [String]
    let relevance: TimelineEntryRelevance?
}

struct DueTodayProvider: TimelineProvider {
    func placeholder(in _: Context) -> DueTodayEntry {
        DueTodayEntry(date: .now, openCount: 2, doneCount: 1, topTitles: ["Pick up the birthday cake"], relevance: nil)
    }

    func getSnapshot(in _: Context, completion: @escaping (DueTodayEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<DueTodayEntry>) -> Void) {
        let entry = loadEntry()
        // Refresh hourly so the day rollover and new captures show up.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: entry.date) ?? entry.date
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    /// Synchronous read of the shared history file — `fileURL` is a
    /// nonisolated constant, so no actor hop is needed inside the provider.
    private func loadEntry() -> DueTodayEntry {
        let calendar = Calendar.current
        var open: [String] = []
        var done = 0

        if let store = RunHistoryStore.sharedOrLocal(),
           let data = try? Data(contentsOf: store.fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let runs = (try? decoder.decode([AssistantRun].self, from: data)) ?? []
            for run in runs {
                for task in run.summary.tasks {
                    guard let dueDate = task.dueDate, calendar.isDateInToday(dueDate) else {
                        continue
                    }
                    if run.isCompleted(task) {
                        done += 1
                    } else {
                        open.append(task.title)
                    }
                }
            }
        }

        // High relevance while tasks are open pushes the widget into the
        // Smart Stack rotation in the morning.
        let relevance = TimelineEntryRelevance(score: open.isEmpty ? 0 : 80)
        return DueTodayEntry(
            date: .now,
            openCount: open.count,
            doneCount: done,
            topTitles: Array(open.prefix(2)),
            relevance: relevance
        )
    }
}

struct DueTodayWidgetView: View {
    var entry: DueTodayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(URL(string: "localassist://today"))
            .containerBackground(for: .widget) {
                Color.clear
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.headline)
                if let first = entry.topTitles.first {
                    Text(first)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: entry.openCount == 0 ? "checkmark.circle.fill" : "sun.max.fill")
                        .foregroundStyle(.tint)
                    Spacer()
                    Text("\(entry.openCount)")
                        .font(.system(.title, design: .rounded, weight: .bold))
                }
                Text(headline)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                ForEach(entry.topTitles, id: \.self) { title in
                    Text("• \(title)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headline: String {
        if entry.openCount == 0 {
            return entry.doneCount > 0 ? "All done today" : "Nothing due today"
        }
        return entry.openCount == 1 ? "1 task due today" : "\(entry.openCount) tasks due today"
    }
}

struct DueTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LocalAssistDueTodayWidget", provider: DueTodayProvider()) { entry in
            DueTodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Due Today")
        .description("Open tasks from your briefs — computed on device from local history.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

@main
struct LocalAssistWidgetBundle: WidgetBundle {
    var body: some Widget {
        CaptureWidget()
        DueTodayWidget()
    }
}
