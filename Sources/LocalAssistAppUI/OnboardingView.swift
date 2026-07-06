import LocalAssistCore
import SwiftUI

/// One screen, three promises. The privacy story is the product.
struct OnboardingView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 12)

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 54, weight: .bold))
                .foregroundStyle(LocalAssistColors.success)

            VStack(spacing: 8) {
                Text("Nothing leaves this phone")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text("LocalAssist turns what you say into a plan — with no account, no API key, and no network.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            VStack(alignment: .leading, spacing: 18) {
                OnboardingRow(
                    symbol: "mic.fill",
                    title: "Capture in seconds",
                    detail: "Speak, scan, paste, or type. On-device speech and Live Text do the transcription."
                )
                OnboardingRow(
                    symbol: "brain.head.profile",
                    title: "Summarized on device",
                    detail: "Apple's on-device model — or an instant rules engine — turns it into a brief with tasks and due dates."
                )
                OnboardingRow(
                    symbol: "checkmark.seal.fill",
                    title: "You confirm every action",
                    detail: "Reminders and calendar holds are only created after you review and tap confirm."
                )
            }
            .padding(.horizontal, 28)

            Spacer()

            Button(action: onContinue) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .interactiveDismissDisabled(false)
    }
}

struct OnboardingRow: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(LocalAssistColors.accent)
                .frame(width: 34, height: 34)
                .background(LocalAssistColors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                Text(detail)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
