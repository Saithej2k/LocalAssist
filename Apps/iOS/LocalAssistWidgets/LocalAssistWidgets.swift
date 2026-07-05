import SwiftUI
import WidgetKit

// Zero-friction capture entry: one tap from the Lock Screen or Home Screen
// deep-links into a live voice capture (localassist://capture). The widget is
// static — no data leaves the device because no data is in it.

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

@main
struct LocalAssistWidgetBundle: WidgetBundle {
    var body: some Widget {
        CaptureWidget()
    }
}
