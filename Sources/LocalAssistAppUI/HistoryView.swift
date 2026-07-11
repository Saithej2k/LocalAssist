import LocalAssistCore
import SwiftUI

struct RunHistoryView: View {
    var runs: [AssistantRun]
    /// Long-press delete on a brief card; nil hides the affordance.
    var onDelete: ((String) -> Void)?
    @State private var query = ""

    private var filteredRuns: [AssistantRun] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return runs
        }
        return runs.filter { run in
            let haystack = (
                [run.summary.headline]
                    + run.summary.keyPoints
                    + run.summary.tasks.map(\.title)
                    + [run.request.sourceText]
            ).joined(separator: " ").lowercased()
            return haystack.contains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recent briefs", symbol: "clock.arrow.circlepath")

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search briefs and tasks", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(.subheadline, design: .rounded))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(LocalAssistColors.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if filteredRuns.isEmpty {
                Label("No briefs match “\(query)”.", systemImage: "magnifyingglass")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            ForEach(filteredRuns.prefix(5), id: \.id) { run in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: run.request.inputKind.symbol)
                        .foregroundStyle(LocalAssistColors.accent)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(run.summary.headline)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .lineLimit(2)
                        Text(historyDetail(for: run))
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(LocalAssistColors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LocalAssistColors.border)
                }
                .contextMenu {
                    if let onDelete {
                        Button(role: .destructive) {
                            onDelete(run.id)
                        } label: {
                            Label("Delete brief", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .panel()
    }

    private func historyDetail(for run: AssistantRun) -> String {
        let kind = run.request.inputKind.shortTitle
        let count = run.summary.tasks.count
        switch count {
        case 0:
            return kind
        case 1:
            return "\(kind) · 1 task"
        default:
            return "\(kind) · \(count) tasks"
        }
    }
}

extension AssistantInputKind {
    var shortTitle: String {
        switch self {
        case .note:
            "Notes"
        case .voiceNote:
            "Voice"
        case .meeting:
            "Meeting"
        case .personalAdmin:
            "Admin"
        }
    }

    var symbol: String {
        switch self {
        case .note:
            "text.alignleft"
        case .voiceNote:
            "mic.fill"
        case .meeting:
            "person.2.fill"
        case .personalAdmin:
            "checklist"
        }
    }
}
