import LocalAssistCore
import SwiftUI

struct SummaryResultView: View {
    var run: AssistantRun
    @StateObject private var speaker = BriefSpeaker()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionHeader(title: "Brief", symbol: "doc.text.magnifyingglass")
                Spacer()
                Button {
                    speaker.toggle(text: BriefSpeaker.spokenText(for: run.summary))
                } label: {
                    Image(systemName: speaker.isSpeaking ? "stop.circle.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LocalAssistColors.accent)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(speaker.isSpeaking ? "Stop reading brief" : "Read brief aloud")
            }
            Text(run.summary.headline)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            // Honest speed: which engine ran and how long it took, so
            // "slow" is a number instead of a feeling.
            Text(generationDetail)
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(run.summary.keyPoints, id: \.self) { point in
                    Label(point, systemImage: "checkmark.circle.fill")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(LocalAssistColors.ink)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(run.summary.suggestions, id: \.id) { suggestion in
                    SuggestionRow(suggestion: suggestion)
                }
            }
        }
        .panel()
    }
}

struct SuggestionRow: View {
    var suggestion: TaskSuggestion

    var body: some View {
        BriefTaskRow(
            title: suggestion.title,
            priority: suggestion.priority,
            dueText: suggestion.iso8601DueDate ?? suggestion.dueHint,
            actionText: suggestion.action.displayTitle
        )
    }
}

/// The one visual a brief task row has, streaming or finished. The
/// completed path passes every field; the streaming path passes nils for
/// fields the model hasn't produced yet and gets placeholder geometry in
/// their place — so a row never re-lays-out when its pills arrive, and the
/// finished brief is the same row fully populated.
struct BriefTaskRow: View {
    var title: String
    var priority: TaskPriority?
    var dueText: String?
    var actionText: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let priority {
                    PriorityDot(priority: priority)
                } else {
                    Circle()
                        .fill(.quaternary)
                        .frame(width: 10, height: 10)
                }
            }
            .padding(.top, 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(.headline, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                HStack(spacing: 6) {
                    if let priority {
                        MetadataPill(text: priority.rawValue.capitalized)
                    } else {
                        MetadataPill(text: "Medium")
                            .redacted(reason: .placeholder)
                    }
                    if let dueText {
                        MetadataPill(text: dueText)
                    }
                    if let actionText {
                        MetadataPill(text: actionText)
                    } else {
                        MetadataPill(text: "Reminder")
                            .redacted(reason: .placeholder)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(LocalAssistColors.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private extension SummaryResultView {
    var generationDetail: String {
        let engine = run.summary.source == .foundationModels ? "on-device model" : "rules engine"
        let seconds = run.metrics.durationMilliseconds / 1000
        if seconds < 0.95 {
            return "\(engine) · \(Int((seconds * 1000).rounded())) ms"
        }
        return "\(engine) · \(String(format: "%.1f", seconds)) s"
    }
}

struct RefineBarView: View {
    @ObservedObject var viewModel: LocalAssistViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Refine on the same session", symbol: "arrow.triangle.2.circlepath")
            HStack(spacing: 10) {
                TextField("e.g. only keep high-priority tasks", text: $viewModel.refineInstruction)
                    .font(.system(.subheadline, design: .rounded))
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(LocalAssistColors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(LocalAssistColors.border)
                    }
                    .onSubmit { viewModel.refine() }

                Button {
                    viewModel.refine()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LocalAssistColors.accent)
                .disabled(
                    viewModel.isGenerating
                        || viewModel.refineInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityLabel("Refine summary")
            }
            Text("Follow-ups reuse the model session, so the previous note and summary stay in context.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .panel()
    }
}

/// The brief, mid-generation. Same skeleton, typography, and row visuals
/// as `SummaryResultView` — headline at title3, real task rows — so
/// completion is this layout finishing in place, not a caption-sized
/// skeleton swapping into a different card. The header spinner and phase
/// line are the only streaming-specific chrome.
struct ProgressPanel: View {
    var phase: SummaryGenerationPhase?
    var message: String?
    var partial: StructuredSummaryPartial?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionHeader(title: "Brief", symbol: "doc.text.magnifyingglass")
                Spacer()
                ProgressView()
                    .frame(width: 44, height: 44)
            }

            if let headline = partial?.overview, !headline.isEmpty {
                Text(headline)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            } else {
                // Headline-shaped placeholder so the card doesn't grow a
                // line when the first tokens land.
                Text("Writing the headline")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .redacted(reason: .placeholder)
            }

            // The phase line sits where the finished card puts its
            // engine-and-latency line, and leaves with it.
            Text(phaseTitle)
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)

            if let partial {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(partial.keyPoints, id: \.self) { point in
                        Label(point, systemImage: "checkmark.circle.fill")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(LocalAssistColors.ink)
                            .transition(.opacity)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    // Row identity is the slot, not the text: guided
                    // generation appends array elements in order and then
                    // revises fields inside them, so slot N stays the same
                    // task for the life of the stream while its title grows
                    // token by token. A text-derived id would tear the row
                    // down on every revision.
                    ForEach(streamingRows) { row in
                        BriefTaskRow(
                            title: row.title,
                            priority: row.priority,
                            dueText: row.dueText,
                            actionText: row.actionText
                        )
                        .transition(.opacity)
                    }
                }
            }
        }
        .panel()
        // Streamed fields fade in as snapshots arrive instead of popping —
        // the WWDC "Code-Along" animation + content-transition recipe.
        // Streamed fields animate in unless the user asked the system for
        // less motion.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: partial)
    }

    private struct StreamingRow: Identifiable {
        let id: Int
        let title: String
        let priority: TaskPriority?
        let dueText: String?
        let actionText: String?
    }

    private var streamingRows: [StreamingRow] {
        guard let partial else {
            return []
        }
        return partial.suggestions.enumerated().compactMap { slot, suggestion in
            guard let title = suggestion.title, !title.isEmpty else {
                return nil
            }
            let dueText: String? = suggestion.dueDate.map {
                LocalAssistDates.dateOnlyString(from: $0)
            } ?? suggestion.dueHint
            return StreamingRow(
                id: slot,
                title: title,
                priority: suggestion.priority,
                dueText: dueText,
                actionText: suggestion.action?.displayTitle
            )
        }
    }

    private var phaseTitle: String {
        switch phase {
        case .validating:
            "Reading input"
        case .checkingAvailability:
            "Preparing brief"
        case .fallback:
            "Finding actions"
        case .streamingModel:
            "Writing brief"
        case .normalizing:
            "Organizing tasks"
        case .completed:
            "Finishing up"
        case nil:
            "Creating brief"
        }
    }
}

#Preview("Streaming — headline only") {
    ProgressPanel(
        phase: .streamingModel,
        message: nil,
        partial: StructuredSummaryPartial(overview: "Three errands before the weekend")
    )
    .padding()
}

#Preview("Streaming — tasks arriving") {
    ProgressPanel(
        phase: .streamingModel,
        message: nil,
        partial: StructuredSummaryPartial(
            overview: "Three errands before the weekend",
            keyPoints: ["Cake pickup is Saturday morning", "Dentist needs booking this week"],
            suggestions: [
                TaskSuggestionPartial(title: "Call Mom tonight", priority: .high),
                TaskSuggestionPartial(title: "Pick up the birthday ca"),
            ]
        )
    )
    .padding()
}
