import LocalAssistCore
import SwiftUI

enum LocalAssistColors {
    #if canImport(UIKit)
        static let canvas = Color(uiColor: .systemGroupedBackground)
        static let surface = Color(uiColor: .secondarySystemGroupedBackground)
        static let row = Color(uiColor: .tertiarySystemGroupedBackground)
        static let border = Color(uiColor: .separator)
        static let ink = Color(uiColor: .label)
    #elseif canImport(AppKit)
        static let canvas = Color(nsColor: .windowBackgroundColor)
        static let surface = Color(nsColor: .controlBackgroundColor)
        static let row = Color(nsColor: .underPageBackgroundColor)
        static let border = Color(nsColor: .separatorColor)
        static let ink = Color(nsColor: .labelColor)
    #else
        static let canvas = Color(.white)
        static let surface = Color(.white)
        static let row = Color(red: 0.944, green: 0.957, blue: 0.964)
        static let border = Color(red: 0.835, green: 0.858, blue: 0.866)
        static let ink = Color(red: 0.105, green: 0.125, blue: 0.145)
    #endif
    static let accent = Color(red: 0.055, green: 0.376, blue: 0.839)
    static let success = Color(red: 0.067, green: 0.482, blue: 0.286)
    static let warning = Color(red: 0.744, green: 0.432, blue: 0.063)
    static let danger = Color(red: 0.745, green: 0.161, blue: 0.145)
}

extension View {
    func panel() -> some View {
        padding(16)
            .background(LocalAssistColors.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LocalAssistColors.border)
            }
    }
}

struct SectionHeader: View {
    var title: String
    var symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(LocalAssistColors.ink)
    }
}

struct PriorityDot: View {
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

struct MetadataPill: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(LocalAssistColors.surface.opacity(0.74), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct StatusPanel: View {
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

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.72))
            .padding(.vertical, 13)
            .background(background(configuration), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func background(_ configuration: Configuration) -> Color {
        guard isEnabled else {
            return LocalAssistColors.accent.opacity(0.34)
        }
        return configuration.isPressed ? LocalAssistColors.accent.opacity(0.78) : LocalAssistColors.accent
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(LocalAssistColors.ink.opacity(isEnabled ? 1 : 0.45))
            .padding(.vertical, 13)
            .background(configuration.isPressed ? LocalAssistColors.row.opacity(0.72) : LocalAssistColors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LocalAssistColors.border)
            }
    }
}

extension SuggestedAction {
    static var reviewCases: [SuggestedAction] {
        [.reminder, .calendarHold, .messageDraft, .checklistItem, .none]
    }

    var displayTitle: String {
        switch self {
        case .reminder:
            "Reminder"
        case .calendarHold:
            "Calendar"
        case .messageDraft:
            "Message"
        case .checklistItem:
            "Checklist"
        case .none:
            "No action"
        }
    }

    var reviewTitle: String {
        switch self {
        case .reminder:
            "Create reminder"
        case .calendarHold:
            "Create calendar hold"
        case .messageDraft:
            "Prepare message draft"
        case .checklistItem:
            "Add checklist item"
        case .none:
            "No action"
        }
    }
}
