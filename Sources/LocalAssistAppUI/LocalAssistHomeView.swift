import LocalAssistCore
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit)
    import AppKit
#endif

/// Top-level navigation: one tab per job. Capture stays a short, focused
/// screen; reviewing today's tasks and browsing history live on their own
/// tabs instead of stacking into one long scroll.
private enum AppTab: Hashable {
    case capture
    case today
    case history
    case settings
}

public struct LocalAssistHomeView: View {
    @StateObject private var viewModel: LocalAssistViewModel
    @StateObject private var voiceTranscriber = VoiceNoteTranscriber()
    @State private var selectedTab: AppTab = .capture
    @State private var didRunLaunchAutomation = false
    @State private var showsOnboarding = false
    @AppStorage("localassist.hasOnboarded") private var hasOnboarded = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    public init(viewModel: LocalAssistViewModel = LocalAssistViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            captureTab
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(AppTab.capture)

            todayTab
                .tabItem {
                    Label("Today", systemImage: "sun.max.fill")
                }
                .tag(AppTab.today)
                .badge(openDueTodayCount)

            historyTab
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(AppTab.history)

            settingsTab
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(AppTab.settings)
        }
        .task {
            viewModel.prewarm()
            viewModel.refreshAvailability()
            viewModel.loadHistory()
            runLaunchAutomationIfNeeded()
            if !hasOnboarded, ProcessInfo.processInfo.environment["LOCALASSIST_AUTO_RUN"] != "1" {
                showsOnboarding = true
            }
        }
        // Prewarm the on-device model the moment the user starts typing —
        // the WWDC "strong hint" heuristic. In Instant mode this is a no-op.
        .onChange(of: viewModel.inputText) { _, _ in
            viewModel.inputChanged()
        }
        .sheet(isPresented: $showsOnboarding, onDismiss: { hasOnboarded = true }) {
            OnboardingView {
                showsOnboarding = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .localAssistCaptureRequested)) { _ in
            selectedTab = .capture
            startExternalCapture()
        }
        .onOpenURL { url in
            if url.host == "capture" || url.path.contains("capture") {
                selectedTab = .capture
                startExternalCapture()
            } else if url.host == "today" || url.path.contains("today") {
                selectedTab = .today
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                return
            }
            drainSharedCaptureIfNeeded()
            viewModel.loadHistory()
        }
    }

    // MARK: - Tabs

    private var captureTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Centered wordmark; settings lives in the tab bar with
                // everything else, so the header is just the name.
                Text("local assist")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .center)

                ModelModePill(
                    usesSmartModel: viewModel.usesSmartModel,
                    availability: viewModel.availability,
                    onToggle: { viewModel.toggleSmartMode() }
                )

                // Capture comes first: pocket-to-captured in seconds.
                InputComposerView(
                    viewModel: viewModel,
                    voiceTranscriber: voiceTranscriber
                )

                if viewModel.isGenerating {
                    ProgressPanel(
                        phase: viewModel.generationPhase,
                        message: viewModel.generationMessage,
                        partial: viewModel.streamingPartial
                    )
                }

                if let errorMessage = viewModel.errorMessage {
                    StatusPanel(
                        symbol: "exclamationmark.triangle.fill",
                        title: "Could not create brief",
                        message: errorMessage,
                        tint: .red
                    )
                }

                if let run = viewModel.run {
                    ActionReviewView(
                        actions: viewModel.preparedActions,
                        executed: viewModel.executedActions,
                        onConfirm: { action in
                            viewModel.confirmAction(action)
                            if let url = LocalAssistViewModel.draftHandoffURL(for: action) {
                                openURL(url)
                            }
                        }
                    )
                    SummaryResultView(run: run)
                    if run.summary.source == .foundationModels {
                        RefineBarView(viewModel: viewModel)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(LocalAssistColors.canvas)
    }

    private var settingsTab: some View {
        NavigationStack {
            SettingsFormView(viewModel: viewModel)
                .navigationTitle("Settings")
        }
    }

    private var todayTab: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TodayView(
                        currentRun: viewModel.run,
                        history: viewModel.history,
                        onToggle: { runID, task in
                            viewModel.toggleTask(runID: runID, task: task)
                        }
                    )
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .background(LocalAssistColors.canvas)
            .navigationTitle("Today")
        }
    }

    private var historyTab: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if viewModel.history.isEmpty {
                        StatusPanel(
                            symbol: "clock.arrow.circlepath",
                            title: "No briefs yet",
                            message: "Captured briefs land here so you can search and revisit them.",
                            tint: .secondary
                        )
                    } else {
                        RunHistoryView(runs: viewModel.history)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .background(LocalAssistColors.canvas)
            .navigationTitle("History")
        }
    }

    /// Open tasks due today across all runs — surfaces as the Today badge.
    private var openDueTodayCount: Int {
        var count = 0
        for run in viewModel.history {
            for task in run.summary.tasks where !run.isCompleted(task) {
                if let due = task.dueDate, Calendar.current.isDateInToday(due) {
                    count += 1
                }
            }
        }
        return count
    }

    /// Picks up text captured via the share extension while the app was away.
    private func drainSharedCaptureIfNeeded() {
        guard let shared = PendingCaptureInbox.drain() else {
            return
        }
        viewModel.inputKind = .note
        viewModel.inputText = viewModel.inputText.isEmpty
            ? shared
            : viewModel.inputText + "\n" + shared
    }

    /// Entry from the App Shortcut or Lock Screen widget: land directly in a
    /// live voice capture.
    private func startExternalCapture() {
        guard !voiceTranscriber.isRecording, !viewModel.isGenerating else {
            return
        }
        CaptureHaptics.recordStart()
        viewModel.prepareVoiceCapture()
        Task {
            await voiceTranscriber.start()
        }
    }
}

/// Physical confirmation that recording started/stopped — trust cue for a
/// capture tool. No-op off iOS. Main-actor because the feedback generator
/// is UI machinery; every call site is a view action anyway.
@MainActor
enum CaptureHaptics {
    static func recordStart() {
        #if os(iOS) && canImport(UIKit)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    static func recordStop() {
        #if os(iOS) && canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

extension LocalAssistHomeView {
    private func runLaunchAutomationIfNeeded() {
        guard !didRunLaunchAutomation else {
            return
        }

        let environment = ProcessInfo.processInfo.environment
        guard environment["LOCALASSIST_AUTO_RUN"] == "1" else {
            return
        }

        didRunLaunchAutomation = true
        if viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.inputText = LocalAssistViewModel.sampleInput
        }
        if environment["LOCALASSIST_FORCE_OFFLINE"] == "1" {
            viewModel.forceOfflineFallbackForAutomation()
        }
        viewModel.summarize()
    }
}

/// Both modes are 100% on-device; the toggle trades deterministic speed for
/// model quality, never privacy. Availability-driven behavior mirrors the
/// WWDC "Code-Along" recipe:
/// - `.deviceNotEligible`: hide the Smart affordance entirely so users don't
///   go down a path their device can't support.
/// - `.appleIntelligenceNotEnabled`: offer a soft "Enable" hint.
/// - `.modelNotReady`: label the button "Try again soon".
private struct ModelModePill: View {
    var usesSmartModel: Bool
    var availability: ModelAvailability?
    var onToggle: () -> Void

    private var unavailabilityReason: ModelUnavailabilityReason? {
        availability?.unavailability?.reason
    }

    var body: some View {
        HStack(spacing: 8) {
            Label(
                usesSmartModel ? "Smart brief · on-device AI" : "Instant brief · rules",
                systemImage: usesSmartModel ? "brain.head.profile" : "bolt.fill"
            )
            .font(.system(.caption, design: .rounded, weight: .bold))
            .foregroundStyle(usesSmartModel ? LocalAssistColors.accent : LocalAssistColors.success)
            .lineLimit(1)
            .minimumScaleFactor(0.78)

            Label("Private", systemImage: "lock.fill")
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            // Skip the Smart affordance entirely on ineligible devices.
            if unavailabilityReason != .deviceNotEligible {
                Button {
                    onToggle()
                } label: {
                    Text(toggleTitle)
                        .font(.system(.caption, design: .rounded, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LocalAssistColors.accent)
                .disabled(unavailabilityReason == .modelNotReady && !usesSmartModel)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect()
        .accessibilityLabel(accessibilityDescription)
    }

    private var toggleTitle: String {
        if usesSmartModel {
            return "Use Instant"
        }
        switch unavailabilityReason {
        case .appleIntelligenceNotEnabled:
            return "Enable Smart"
        case .modelNotReady:
            return "Preparing…"
        default:
            return "Use Smart"
        }
    }

    private var accessibilityDescription: String {
        if usesSmartModel {
            return "Smart brief mode, on-device AI, private"
        }
        return "Instant brief mode, rule-based, private"
    }
}

/// One text box, one mic, one primary action, one clear — the app figures
/// out what the text is (meeting recap, errands, notes) so the user never
/// files their own thoughts into categories. Controls float on Liquid Glass;
/// the editor stays a plain content surface, per the platform's layering.
private struct InputComposerView: View {
    @ObservedObject var viewModel: LocalAssistViewModel
    @ObservedObject var voiceTranscriber: VoiceNoteTranscriber
    #if os(iOS)
        @State private var isEditorFocused = false
        @State private var scanRequestCount = 0
    #else
        @FocusState private var editorFocused: Bool
    #endif
    private var hasText: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topLeading) {
                #if os(iOS)
                    CaptureTextView(
                        text: $viewModel.inputText,
                        isFocused: $isEditorFocused,
                        scanRequestCount: $scanRequestCount
                    )
                    .frame(minHeight: 170)
                #else
                    TextEditor(text: $viewModel.inputText)
                        .font(.system(.body, design: .rounded))
                        .frame(minHeight: 170)
                        .padding(12)
                        .scrollContentBackground(.hidden)
                        .focused($editorFocused)
                #endif

                if !hasText {
                    Text("What's on your mind? Tasks, meeting notes, errands — say it, scan it, or type it.")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 20)
                        .allowsHitTesting(false)
                }
            }
            .background(LocalAssistColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(LocalAssistColors.border.opacity(0.6))
            }
            // One-tap clear, right where the text is — not buried in Settings.
            .overlay(alignment: .topTrailing) {
                if !viewModel.inputText.isEmpty {
                    Button {
                        viewModel.inputText = ""
                        viewModel.inputKind = .note
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear text")
                }
            }

            // Live feedback only: while listening, waiting on permission, or
            // when something went wrong. The finished transcript lives in the
            // text box — no lingering status bar repeating it.
            if voiceTranscriber.isRecording || voiceTranscriber.state == .requestingPermission || voiceTranscriber.errorMessage != nil {
                CompactVoiceStatusView(transcriber: voiceTranscriber)
            }

            // Control row: everything actionable lives on one glass shelf.
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        if voiceTranscriber.isRecording {
                            CaptureHaptics.recordStop()
                            voiceTranscriber.stop()
                        } else {
                            CaptureHaptics.recordStart()
                            // Snapshot synchronously, before any transcript
                            // can arrive — dictation appends to this.
                            viewModel.prepareVoiceCapture()
                            Task {
                                await voiceTranscriber.start()
                            }
                        }
                    } label: {
                        Image(systemName: voiceTranscriber.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 20, weight: .bold))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(voiceTranscriber.isRecording ? LocalAssistColors.danger : LocalAssistColors.accent)
                    .disabled(viewModel.isGenerating || voiceTranscriber.state == .requestingPermission)
                    .accessibilityLabel(voiceTranscriber.isRecording ? "Stop voice capture" : "Start voice capture")

                    #if os(iOS)
                        // System "Scan Text" camera (the AutoFill flow) —
                        // live Live Text straight into the box.
                        if CaptureTextView.supportsCameraScan {
                            Button {
                                scanRequestCount += 1
                            } label: {
                                Image(systemName: "text.viewfinder")
                                    .font(.system(size: 18, weight: .semibold))
                                    .frame(width: 36, height: 36)
                            }
                            .buttonStyle(.glass)
                            .disabled(viewModel.isGenerating || voiceTranscriber.isRecording)
                            .accessibilityLabel("Scan text with the camera")
                        }
                    #endif

                    Spacer(minLength: 0)

                    if viewModel.isGenerating {
                        Button {
                            viewModel.cancel()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .font(.system(.body, design: .rounded, weight: .bold))
                                .frame(height: 30)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Cancel generation")
                    } else {
                        Button {
                            dismissEditor()
                            viewModel.summarize()
                        } label: {
                            Label("Generate", systemImage: "sparkles")
                                .font(.system(.body, design: .rounded, weight: .bold))
                                .frame(height: 30)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(LocalAssistColors.accent)
                        .disabled(voiceTranscriber.isRecording || !hasText)
                        .accessibilityLabel("Generate brief and review actions")
                    }
                }
            }
        }
        .onChange(of: voiceTranscriber.transcript) { _, newValue in
            viewModel.mergeVoiceTranscript(newValue)
        }
    }

    private func dismissEditor() {
        #if os(iOS)
            isEditorFocused = false
        #else
            editorFocused = false
        #endif
    }
}

private struct CompactVoiceStatusView: View {
    @ObservedObject var transcriber: VoiceNoteTranscriber

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(statusColor)
                .frame(width: 30, height: 30)
                .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.system(.caption, design: .rounded, weight: .bold))
                Text(statusDetail)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if transcriber.isRecording {
                VoiceLevelBars()
            }
        }
        .padding(10)
        .background(LocalAssistColors.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var statusIcon: String {
        if transcriber.errorMessage != nil {
            return "exclamationmark.triangle.fill"
        }
        return transcriber.isRecording ? "waveform" : "mic.fill"
    }

    private var statusColor: Color {
        if transcriber.errorMessage != nil {
            return LocalAssistColors.warning
        }
        return transcriber.isRecording ? LocalAssistColors.danger : LocalAssistColors.accent
    }

    private var statusTitle: String {
        if transcriber.errorMessage != nil {
            return "Voice needs attention"
        }
        switch transcriber.state {
        case .idle:
            return transcriber.transcript.isEmpty ? "Voice note" : "Transcript ready"
        case .requestingPermission:
            return "Requesting access"
        case .recording:
            return "Listening"
        case .unavailable:
            return "Voice unavailable"
        }
    }

    private var statusDetail: String {
        if let message = transcriber.errorMessage {
            return message
        }
        if transcriber.isRecording {
            return "Speak naturally. Your transcript will appear in the capture box."
        }
        if transcriber.transcript.isEmpty {
            return "Tap the mic to dictate instead of typing."
        }
        return "Edit the transcript, then review the suggested actions."
    }
}

private struct VoiceLevelBars: View {
    private let heights: [CGFloat] = [8, 16, 24, 14, 20]

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(LocalAssistColors.danger.opacity(0.72))
                    .frame(width: 4, height: height)
            }
        }
        .frame(height: 28, alignment: .center)
    }
}
