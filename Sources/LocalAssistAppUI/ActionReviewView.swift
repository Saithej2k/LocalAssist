import LocalAssistCore
import SwiftUI

struct ActionReviewView: View {
    var actions: [PreparedToolAction]
    var executed: [String: ExecutedToolAction]
    var onConfirm: (PreparedToolAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader(title: "Review next actions", symbol: "checklist.checked")
                Text("Edit anything first. Nothing is added until you confirm.")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if actions.isEmpty {
                Label("No actions need review from this capture.", systemImage: "checkmark.circle")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(actions) { action in
                    EditableActionCard(
                        action: action,
                        result: executed[action.id],
                        onConfirm: onConfirm
                    )
                }
            }
        }
        .panel()
    }
}

struct EditableActionCard: View {
    var action: PreparedToolAction
    var result: ExecutedToolAction?
    var onConfirm: (PreparedToolAction) -> Void

    @State private var kind: SuggestedAction
    @State private var title: String
    @State private var dateText: String
    @State private var notes: String
    @State private var isIgnored = false

    init(
        action: PreparedToolAction,
        result: ExecutedToolAction?,
        onConfirm: @escaping (PreparedToolAction) -> Void
    ) {
        self.action = action
        self.result = result
        self.onConfirm = onConfirm
        _kind = State(initialValue: action.draft.kind == .none ? .reminder : action.draft.kind)
        _title = State(initialValue: Self.initialTitle(for: action))
        _dateText = State(initialValue: Self.initialDate(for: action))
        _notes = State(initialValue: Self.initialNotes(for: action))
    }

    var body: some View {
        if isIgnored {
            HStack(spacing: 10) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
                Text("Ignored")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Undo") {
                    isIgnored = false
                }
                .font(.system(.caption, design: .rounded, weight: .bold))
            }
            .padding(12)
            .background(LocalAssistColors.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon(for: kind))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LocalAssistColors.accent)
                        .frame(width: 38, height: 38)
                        .background(LocalAssistColors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        // The picker already names the kind — a second static
                        // label crowded the row until "Message" hyphenated.
                        HStack {
                            if action.draft.payload["priority"] == "urgent" {
                                Label("Priority", systemImage: "exclamationmark.circle.fill")
                                    .font(.system(.caption2, design: .rounded, weight: .bold))
                                    .foregroundStyle(LocalAssistColors.warning)
                                    .labelStyle(.titleAndIcon)
                            }
                            Spacer(minLength: 8)
                            Picker("Action type", selection: $kind) {
                                ForEach(SuggestedAction.reviewCases, id: \.self) { actionKind in
                                    Text(actionKind.displayTitle).tag(actionKind)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }

                        TextField("Action title", text: $title, axis: .vertical)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .textFieldStyle(.plain)
                            .lineLimit(1 ... 3)
                            // Without an explicit vertical fit the field
                            // clips its own descenders ("doing" read "doina").
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        TextField("Date or reminder time", text: $dateText)
                            .textFieldStyle(.plain)
                    }

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "note.text")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                            .padding(.top, 2)
                        TextField("Notes", text: $notes, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1 ... 3)
                    }
                }
                .font(.system(.subheadline, design: .rounded))
                .padding(11)
                .background(LocalAssistColors.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if let result {
                    Label(result.detail, systemImage: result.didWriteToSystem ? "checkmark.seal.fill" : "info.circle")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(result.didWriteToSystem ? LocalAssistColors.success : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 10) {
                        Button {
                            isIgnored = true
                        } label: {
                            Text("Ignore")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryActionButtonStyle())

                        if kind != .none {
                            Button {
                                onConfirm(editedAction)
                            } label: {
                                Label(confirmLabel(for: kind), systemImage: "checkmark.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            .padding(12)
            .background(LocalAssistColors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LocalAssistColors.border)
            }
        }
    }

    private var editedAction: PreparedToolAction {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDate = dateText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload = action.draft.payload

        payload["title"] = cleanTitle
        payload["subject"] = cleanTitle

        if cleanDate.isEmpty {
            payload.removeValue(forKey: "dueHint")
            payload.removeValue(forKey: "dueDate")
            payload.removeValue(forKey: "dateHint")
            payload.removeValue(forKey: "date")
        } else if kind == .calendarHold {
            // The user's text is now the only date: stale machine keys would
            // outrank it in the executor's `date ?? dateHint` lookup.
            payload["dateHint"] = cleanDate
            payload.removeValue(forKey: "date")
        } else {
            payload["dueHint"] = cleanDate
            payload.removeValue(forKey: "dueDate")
        }

        if cleanNotes.isEmpty {
            payload.removeValue(forKey: "notes")
            payload.removeValue(forKey: "body")
        } else {
            payload["notes"] = cleanNotes
            payload["body"] = cleanNotes
        }

        if kind == .calendarHold, payload["duration"] == nil {
            payload["duration"] = "30m"
        }

        let draft = ToolActionDraft(
            kind: kind,
            title: kind.reviewTitle,
            payload: payload,
            requiresConfirmation: kind != .none
        )
        return PreparedToolAction(
            id: action.id,
            draft: draft,
            state: kind == .none ? .noActionRequired : .readyForConfirmation,
            confirmationTitle: kind.reviewTitle,
            confirmationMessage: "Reviewed in local assist."
        )
    }

    private func confirmLabel(for kind: SuggestedAction) -> String {
        switch kind {
        case .reminder, .checklistItem:
            "Add to Reminders"
        case .calendarHold:
            "Add to Calendar"
        case .messageDraft:
            "Prepare Message"
        case .none:
            "Confirm"
        }
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

    private static func initialTitle(for action: PreparedToolAction) -> String {
        action.draft.payload["title"]
            ?? action.draft.payload["subject"]
            ?? action.confirmationTitle
    }

    private static func initialDate(for action: PreparedToolAction) -> String {
        action.draft.payload["dueDate"]
            ?? action.draft.payload["date"]
            ?? action.draft.payload["dueHint"]
            ?? action.draft.payload["dateHint"]
            ?? ""
    }

    private static func initialNotes(for action: PreparedToolAction) -> String {
        action.draft.payload["notes"]
            ?? action.draft.payload["body"]
            ?? ""
    }
}
