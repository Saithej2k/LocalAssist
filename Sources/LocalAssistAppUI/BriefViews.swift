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
        HStack(alignment: .top, spacing: 12) {
            PriorityDot(priority: suggestion.priority)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(suggestion.title)
                    .font(.system(.headline, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    MetadataPill(text: suggestion.priority.rawValue.capitalized)
                    if let dueDate = suggestion.iso8601DueDate {
                        MetadataPill(text: dueDate)
                    } else if let dueHint = suggestion.dueHint {
                        MetadataPill(text: dueHint)
                    }
                    MetadataPill(text: actionLabel(for: suggestion.action))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(LocalAssistColors.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func actionLabel(for action: SuggestedAction) -> String {
        action.displayTitle
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

/// Typed streaming skeleton: headline first, then key points and
/// suggestion titles fill in as the model generates.
struct ProgressPanel: View {
    var phase: SummaryGenerationPhase?
    var message: String?
    var partial: StructuredSummaryPartial?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 3) {
                    Text(phaseTitle)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    Text("Pulling out the useful pieces.")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let partial {
                VStack(alignment: .leading, spacing: 8) {
                    if let headline = partial.overview, !headline.isEmpty {
                        Text(headline)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                    }
                    ForEach(partial.keyPoints, id: \.self) { point in
                        Label(point, systemImage: "circle.dotted")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    ForEach(Array(partial.suggestions.enumerated()), id: \.offset) { _, suggestion in
                        if let title = suggestion.title, !title.isEmpty {
                            Label {
                                Text("\(title)\(dueText(for: suggestion))")
                                    .contentTransition(.opacity)
                            } icon: {
                                Image(systemName: "arrow.right.circle")
                            }
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .transition(.opacity)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LocalAssistColors.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .panel()
        // Streamed fields fade in as snapshots arrive instead of popping —
        // the WWDC "Code-Along" animation + content-transition recipe.
        // Streamed fields animate in unless the user asked the system for
        // less motion.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: partial)
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

    private func dueText(for suggestion: TaskSuggestionPartial) -> String {
        if let dueDate = suggestion.dueDate {
            return " · \(LocalAssistDates.dateOnlyString(from: dueDate))"
        }
        if let dueHint = suggestion.dueHint {
            return " · \(dueHint)"
        }
        return ""
    }
}
