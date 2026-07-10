import LocalAssistCore
import SwiftUI

struct SettingsFormView: View {
    @ObservedObject var viewModel: LocalAssistViewModel
    /// Cached so the O(history) export builds run on appearance and
    /// history changes, not on every Form render.
    @State private var markdownExportURL: URL?
    @State private var jsonExportURL: URL?
    @State private var transcriptEntries: [TranscriptEntrySnapshot] = []
    @State private var transcriptExpanded = false
    @AppStorage(LocalAssistViewModel.priorityContactsDefaultsKey)
    private var priorityContacts = LocalAssistViewModel.defaultPriorityContacts

    private var smartModeAvailable: Bool {
        viewModel.availability?.unavailability?.reason != .deviceNotEligible
    }

    private var processingFooter: String {
        let baseline = "Both modes run entirely on this phone. Smart uses Apple's on-device model for richer briefs; Instant uses deterministic rules and works on every device."
        guard let unavailability = viewModel.availability?.unavailability else {
            return baseline
        }
        return "\(baseline)\n\n\(unavailability.userGuidance)"
    }

    var body: some View {
        Form {
            Section {
                if smartModeAvailable {
                    Toggle(isOn: smartModeBinding) {
                        Label("Smart brief (on-device AI)", systemImage: "brain.head.profile")
                    }
                    .disabled(viewModel.availability?.unavailability?.reason == .modelNotReady)
                } else {
                    Label("Smart brief not supported on this device", systemImage: "brain.head.profile")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Processing")
            } footer: {
                Text(processingFooter)
            }

            Section {
                Toggle(isOn: morningBriefBinding) {
                    Label("Morning brief at 8:30", systemImage: "sun.max.fill")
                }
            } header: {
                Text("Daily moment")
            } footer: {
                Text("One local notification each morning with what's due today and what you captured yesterday. Scheduled on device — nothing is sent anywhere.")
            }

            Section {
                TextField("mom, dad, Anika", text: $priorityContacts)
                    .autocorrectionDisabled()
            } header: {
                Text("Priority contacts")
            } footer: {
                Text(
                    "Messages and emails mentioning these people jump to the top of the action list. "
                        + "Separate names with commas. The list stays on this phone."
                )
            }

            Section {
                if let markdownExportURL {
                    ShareLink(item: markdownExportURL) {
                        Label("Export history (Markdown)", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Label("Export history (Markdown)", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                }
                if let jsonExportURL {
                    ShareLink(item: jsonExportURL) {
                        Label("Export history (JSON)", systemImage: "curlybraces.square")
                    }
                } else {
                    Label("Export history (JSON)", systemImage: "curlybraces.square")
                        .foregroundStyle(.secondary)
                }
                Button {
                    viewModel.clearDraft()
                } label: {
                    Label("Clear current draft", systemImage: "xmark.circle")
                }
                Button(role: .destructive) {
                    viewModel.clearHistory()
                } label: {
                    Label("Clear history", systemImage: "trash")
                }
            } header: {
                Text("Data")
            } footer: {
                Text("History lives in a private JSON file in the app's container.")
            }

            Section {
                DisclosureGroup(isExpanded: $transcriptExpanded) {
                    if transcriptEntries.isEmpty {
                        Text("No model session yet — run a Smart brief first.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(transcriptEntries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.kind.displayTitle)
                                    .font(.system(.caption, design: .rounded, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Text(entry.text)
                                    .font(.system(.caption, design: .rounded))
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } label: {
                    Label("Model session transcript", systemImage: "list.bullet.rectangle")
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text(
                    "Read-only view of the current model session — instructions, prompts, "
                        + "tool calls, and responses, each truncated for display. Stays on this phone."
                )
            }

            Section {
            } footer: {
                Text("LocalAssist \(Self.versionString) — everything on this device.")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onAppear {
            refreshExports()
        }
        .onChange(of: viewModel.history) { _, _ in
            refreshExports()
        }
        // The transcript loads when the group opens and again after each
        // run — sessions grow per turn and rebuild on context overflow, so
        // a cached copy would quietly go stale.
        .onChange(of: transcriptExpanded) { _, expanded in
            if expanded {
                refreshTranscript()
            }
        }
        .onChange(of: viewModel.run) { _, _ in
            if transcriptExpanded {
                refreshTranscript()
            }
        }
    }

    private func refreshTranscript() {
        Task {
            transcriptEntries = await viewModel.transcriptDiagnostics()
        }
    }

    private func refreshExports() {
        let exports = viewModel.exportFileURLs()
        markdownExportURL = exports.markdown
        jsonExportURL = exports.json
    }

    static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "v\(version) (\(build))"
    }

    private var smartModeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.usesSmartModel },
            set: { newValue in
                if newValue != viewModel.usesSmartModel {
                    viewModel.toggleSmartMode()
                }
            }
        )
    }

    private var morningBriefBinding: Binding<Bool> {
        Binding(
            get: { viewModel.morningBriefEnabled },
            set: { viewModel.setMorningBrief(enabled: $0) }
        )
    }
}
