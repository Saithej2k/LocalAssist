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
}

public struct LocalAssistHomeView: View {
    @StateObject private var viewModel: LocalAssistViewModel
    @StateObject private var voiceTranscriber = VoiceNoteTranscriber()
    @State private var selectedTab: AppTab = .capture
    @State private var didRunLaunchAutomation = false
    @State private var showsSettings = false
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
                    Label("Capture", systemImage: "square.and.pencil")
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
                // Compact top-left header: app name where every app puts it,
                // settings on the trailing edge, no dead navigation chrome.
                HStack(alignment: .center) {
                    Text("local assist")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Spacer(minLength: 12)
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Settings")
                }

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
        .sheet(isPresented: $showsSettings) {
            SettingsSheetView(viewModel: viewModel)
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
        Task {
            await voiceTranscriber.start()
        }
    }
}

/// Physical confirmation that recording started/stopped — trust cue for a
/// capture tool. No-op off iOS.
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

private struct TodayView: View {
    struct TodayItem: Identifiable {
        var runID: String
        var task: TaskSuggestion
        var isDone: Bool

        var id: String { "\(runID)-\(task.id)" }
    }

    var currentRun: AssistantRun?
    var history: [AssistantRun]
    var onToggle: (String, TaskSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Today", symbol: "sun.max.fill")

            HStack(spacing: 10) {
                TodayMetric(title: "Due today", value: "\(dueToday.filter { !$0.isDone }.count)", tint: LocalAssistColors.danger)
                TodayMetric(title: "Done", value: "\(allItems.filter(\.isDone).count)", tint: LocalAssistColors.success)
                TodayMetric(title: "Captures", value: "\(allRuns.count)", tint: LocalAssistColors.accent)
            }

            if nextActions.isEmpty {
                Label("No actions yet. Capture a note or dictate a thought to build today’s list.", systemImage: "tray")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(nextActions.prefix(5)) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                onToggle(item.runID, item.task)
                            } label: {
                                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(item.isDone ? LocalAssistColors.success : .secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.isDone ? "Mark \(item.task.title) as not done" : "Mark \(item.task.title) as done")

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.task.title)
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                    .strikethrough(item.isDone)
                                    .foregroundStyle(item.isDone ? .secondary : .primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(todayDetail(for: item.task))
                                    .font(.system(.caption, design: .rounded, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            PriorityDot(priority: item.task.priority)
                                .padding(.top, 6)
                        }
                    }
                }
            }
        }
        .panel()
    }

    /// History already contains the current run after it is recorded; only
    /// prepend it when it has not been persisted yet.
    private var allRuns: [AssistantRun] {
        var runs = history
        if let currentRun, !runs.contains(where: { $0.id == currentRun.id }) {
            runs.insert(currentRun, at: 0)
        }
        return runs
    }

    private var allItems: [TodayItem] {
        allRuns.flatMap { run in
            run.summary.tasks.map { task in
                TodayItem(runID: run.id, task: task, isDone: run.isCompleted(task))
            }
        }
    }

    private var dueToday: [TodayItem] {
        allItems.filter { item in
            guard let dueDate = item.task.dueDate else {
                return false
            }
            return Calendar.current.isDateInToday(dueDate)
        }
    }

    private var nextActions: [TodayItem] {
        let todayIDs = Set(dueToday.map(\.id))
        let prioritized = allItems.filter { item in
            todayIDs.contains(item.id) || item.task.priority == .high || item.task.action != .none
        }
        // Open tasks first, done tasks sink to the bottom of the list.
        return Array(prioritized.sorted { !$0.isDone && $1.isDone }.prefix(6))
    }

    private func todayDetail(for suggestion: TaskSuggestion) -> String {
        let action = suggestion.action.displayTitle
        if let dueDate = suggestion.iso8601DueDate {
            return "\(action) · \(dueDate)"
        }
        if let dueHint = suggestion.dueHint {
            return "\(action) · \(dueHint)"
        }
        return action
    }
}

private struct TodayMetric: View {
    var title: String
    var value: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    /// Text that was already in the box when recording started, so dictation
    /// appends to typed notes instead of overwriting them.
    @State private var voiceBaseText = ""

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
                        voiceBaseText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(10)
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
                            Task {
                                await voiceTranscriber.start()
                            }
                        }
                    } label: {
                        Image(systemName: voiceTranscriber.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 20, weight: .bold))
                            .frame(width: 30, height: 30)
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
                                    .frame(width: 30, height: 30)
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
        // Snapshot the box the moment any recording starts — mic button,
        // App Shortcut, or Lock Screen widget all flow through here.
        .onChange(of: voiceTranscriber.isRecording) { _, isRecording in
            if isRecording {
                voiceBaseText = viewModel.inputText
            }
        }
        .onChange(of: voiceTranscriber.transcript) { _, newValue in
            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            // Voice is known to be voice only once words actually arrive.
            viewModel.inputKind = .voiceNote
            viewModel.inputText = voiceBaseText.isEmpty
                ? newValue
                : voiceBaseText + "\n" + newValue
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

private struct SummaryResultView: View {
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

private struct MetadataPill: View {
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

private struct RefineBarView: View {
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

private struct ActionReviewView: View {
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

private struct EditableActionCard: View {
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
                        HStack {
                            Text(kind.displayTitle)
                                .font(.system(.caption, design: .rounded, weight: .bold))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Picker("Action type", selection: $kind) {
                                ForEach(SuggestedAction.reviewCases, id: \.self) { actionKind in
                                    Text(actionKind.displayTitle).tag(actionKind)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        TextField("Action title", text: $title, axis: .vertical)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .textFieldStyle(.plain)
                            .lineLimit(1 ... 3)
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
            payload["dateHint"] = cleanDate
        } else {
            payload["dueHint"] = cleanDate
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

private struct RunHistoryView: View {
    var runs: [AssistantRun]
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

/// Typed streaming skeleton: headline first, then key points and
/// suggestion titles fill in as the model generates.
private struct ProgressPanel: View {
    var phase: SummaryGenerationPhase?
    var message: String?
    var partial: StructuredSummaryPartial?

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
        .animation(.easeOut(duration: 0.25), value: partial)
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

private struct SecondaryActionButtonStyle: ButtonStyle {
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

private extension View {
    func panel() -> some View {
        padding(16)
            .background(LocalAssistColors.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LocalAssistColors.border)
            }
    }
}

private extension AssistantInputKind {
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

private extension SuggestedAction {
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

/// One screen, three promises. The privacy story is the product.
private struct OnboardingView: View {
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

private struct OnboardingRow: View {
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

private struct SettingsSheetView: View {
    @ObservedObject var viewModel: LocalAssistViewModel
    @Environment(\.dismiss) private var dismiss

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
        NavigationStack {
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
                    ShareLink(item: viewModel.exportMarkdown()) {
                        Label("Export history (Markdown)", systemImage: "square.and.arrow.up")
                    }
                    .disabled(viewModel.history.isEmpty)
                    Button {
                        viewModel.clearDraft()
                        dismiss()
                    } label: {
                        Label("Clear current draft", systemImage: "xmark.circle")
                    }
                    Button(role: .destructive) {
                        viewModel.clearHistory()
                        dismiss()
                    } label: {
                        Label("Clear history", systemImage: "trash")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("History lives in a private JSON file in the app's container.")
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
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

private enum LocalAssistColors {
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
