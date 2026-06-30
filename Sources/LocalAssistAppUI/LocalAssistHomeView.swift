import LocalAssistCore
import SwiftUI

public struct LocalAssistHomeView: View {
    @StateObject private var viewModel: LocalAssistViewModel

    public init(viewModel: LocalAssistViewModel = LocalAssistViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AppHeaderView(availability: viewModel.availability)
                    InputComposerView(viewModel: viewModel)

                    if let errorMessage = viewModel.errorMessage {
                        StatusPanel(
                            symbol: "exclamationmark.triangle.fill",
                            title: "Could not summarize",
                            message: errorMessage,
                            tint: .red
                        )
                    }

                    if viewModel.isGenerating {
                        ProgressPanel()
                    }

                    if let run = viewModel.run {
                        SummaryResultView(run: run)
                        ActionDraftsView(actions: viewModel.preparedActions)
                        MetricsView(metrics: run.metrics)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .background(LocalAssistColors.canvas)
            .navigationTitle("LocalAssist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.resetSample()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .accessibilityLabel("Reset sample")
                }
            }
        }
        .task {
            viewModel.refreshAvailability()
        }
    }
}

private struct AppHeaderView: View {
    var availability: ModelAvailability?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Today")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .lineLimit(2)
                }

                Spacer(minLength: 12)
                AvailabilityBadge(availability: availability)
            }

            Text(availability?.isAvailable == true ? "On-device model ready" : "Offline fallback ready")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct InputComposerView: View {
    @ObservedObject var viewModel: LocalAssistViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Source text", systemImage: "text.alignleft")
                    .font(.system(.headline, design: .rounded))
                Spacer()
                Text("\(viewModel.inputText.count) chars")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $viewModel.inputText)
                .font(.system(.body, design: .rounded))
                .frame(minHeight: 150)
                .padding(10)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LocalAssistColors.border)
                }

            VStack(spacing: 12) {
                HStack {
                    Label("Suggestions", systemImage: "slider.horizontal.3")
                    Spacer()
                    Text("\(Int(viewModel.maxSuggestions.rounded()))")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                }
                Slider(value: $viewModel.maxSuggestions, in: 1...8, step: 1)

                Toggle(isOn: $viewModel.forceOfflineFallback) {
                    Label("Force offline fallback", systemImage: "wifi.slash")
                }
            }
            .font(.system(.subheadline, design: .rounded))

            HStack(spacing: 12) {
                Button {
                    viewModel.summarize()
                } label: {
                    Label(viewModel.isGenerating ? "Running" : "Generate", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(viewModel.isGenerating || viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    viewModel.cancel()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(SecondaryIconButtonStyle())
                .disabled(!viewModel.isGenerating)
                .accessibilityLabel("Cancel generation")
            }
        }
        .panel()
    }
}

private struct SummaryResultView: View {
    var run: AssistantRun

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Summary", symbol: "doc.text.magnifyingglass")
            Text(run.summary.overview)
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

private struct SuggestionRow: View {
    var suggestion: TaskSuggestion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PriorityDot(priority: suggestion.priority)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(suggestion.title)
                    .font(.system(.headline, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(suggestion.priority.rawValue.capitalized)
                    if let dueHint = suggestion.dueHint {
                        Text(dueHint)
                    }
                    Text(suggestion.action.rawValue)
                }
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(LocalAssistColors.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ActionDraftsView: View {
    var actions: [PreparedToolAction]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Action drafts", symbol: "checklist.checked")

            ForEach(actions) { action in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon(for: action.draft.kind))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LocalAssistColors.accent)
                        .frame(width: 30, height: 30)
                        .background(LocalAssistColors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(action.confirmationTitle)
                            .font(.system(.headline, design: .rounded))
                        Text(action.confirmationMessage)
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: action.state == .readyForConfirmation ? "hand.tap.fill" : "checkmark")
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LocalAssistColors.border)
                }
            }
        }
        .panel()
    }

    private func icon(for action: SuggestedAction) -> String {
        switch action {
        case .reminder:
            "bell.badge.fill"
        case .calendarHold:
            "calendar.badge.plus"
        case .messageDraft:
            "paperplane.fill"
        case .checklistItem:
            "checklist"
        case .none:
            "minus.circle"
        }
    }
}

private struct MetricsView: View {
    var metrics: RunMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Run metrics", symbol: "speedometer")
            HStack(spacing: 10) {
                MetricTile(title: "Latency", value: "\(metrics.durationMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms")
                MetricTile(title: "Source", value: metrics.source == .foundationModels ? "Model" : "Fallback")
                MetricTile(title: "Drafts", value: "\(metrics.actionDraftCount)")
            }
        }
        .panel()
    }
}

private struct MetricTile: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.headline, design: .rounded, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(LocalAssistColors.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AvailabilityBadge: View {
    var availability: ModelAvailability?

    var body: some View {
        let available = availability?.isAvailable == true
        Label(available ? "Ready" : "Offline", systemImage: available ? "bolt.circle.fill" : "wifi.slash")
            .font(.system(.caption, design: .rounded, weight: .bold))
            .foregroundStyle(available ? LocalAssistColors.success : LocalAssistColors.warning)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white, in: Capsule())
            .overlay {
                Capsule().stroke(LocalAssistColors.border)
            }
    }
}

private struct SectionHeader: View {
    var title: String
    var symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(LocalAssistColors.ink)
    }
}

private struct PriorityDot: View {
    var priority: TaskPriority

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }

    private var color: Color {
        switch priority {
        case .high:
            LocalAssistColors.danger
        case .medium:
            LocalAssistColors.warning
        case .low:
            LocalAssistColors.success
        }
    }
}

private struct ProgressPanel: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Generating locally")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
            Spacer()
        }
        .panel()
    }
}

private struct StatusPanel: View {
    var symbol: String
    var title: String
    var message: String
    var tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.headline, design: .rounded))
                Text(message)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .panel()
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(.white)
            .padding(.vertical, 13)
            .background(configuration.isPressed ? LocalAssistColors.accent.opacity(0.78) : LocalAssistColors.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SecondaryIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(LocalAssistColors.ink)
            .background(configuration.isPressed ? LocalAssistColors.row.opacity(0.7) : Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LocalAssistColors.border)
            }
    }
}

private extension View {
    func panel() -> some View {
        padding(16)
            .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LocalAssistColors.border)
            }
    }
}

private enum LocalAssistColors {
    static let canvas = Color(red: 0.965, green: 0.968, blue: 0.955)
    static let row = Color(red: 0.944, green: 0.957, blue: 0.964)
    static let border = Color(red: 0.835, green: 0.858, blue: 0.866)
    static let ink = Color(red: 0.105, green: 0.125, blue: 0.145)
    static let accent = Color(red: 0.055, green: 0.376, blue: 0.839)
    static let success = Color(red: 0.067, green: 0.482, blue: 0.286)
    static let warning = Color(red: 0.744, green: 0.432, blue: 0.063)
    static let danger = Color(red: 0.745, green: 0.161, blue: 0.145)
}
