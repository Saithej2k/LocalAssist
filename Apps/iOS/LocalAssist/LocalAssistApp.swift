import LocalAssistAppIntents
import LocalAssistAppUI
import LocalAssistCore
import SwiftUI

@main
struct LocalAssistApp: App {
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
        /// True once a `LOCALASSIST_MEASURE_PROCESS_COLD` launch finished
        /// its single sample — surfaced as an accessibility marker so the
        /// cold-launch XCUITest can wait on it instead of sleeping.
        @State private var processColdSampleDone = false
    #endif

    init() {
        // Crash/hang payloads from MetricKit, written to local files only —
        // even diagnostics never leave the device.
        LocalDiagnostics.start()
    }

    var body: some Scene {
        WindowGroup {
            LocalAssistHomeView()
                // Deletion cleanup runs promptly after the user deletes a
                // brief; the scenePhase pass below is the launch retry for
                // anything a crash or index failure left pending.
                .onReceive(NotificationCenter.default.publisher(for: .localAssistHistoryDidDelete)) { _ in
                    Task {
                        await SpotlightDeletionCoordinator.live()?.processPending()
                    }
                }
                #if DEBUG
                .task {
                    // No-op unless the launch argument is set; when it is,
                    // this is the process's first generation — the genuine
                    // process-cold sample the warm-loop harness cannot make.
                    if await DeviceMeasurementHarness.runProcessColdSampleIfRequested() {
                        processColdSampleDone = true
                    }
                }
                .overlay {
                    if processColdSampleDone {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityElement()
                            .accessibilityIdentifier("measurement-cold-done")
                    }
                }
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                return
            }
            Task {
                // Retry any Spotlight deletions a previous session failed to
                // confirm, then re-donate what remains. Order matters: a
                // donation running first would race the deletion pass.
                await SpotlightDeletionCoordinator.live()?.processPending()
                // Keep briefs searchable from Spotlight (and eligible for
                // Siri personal context) — donation is local-only.
                await LocalAssistSpotlight.donateAll()
            }
        }
    }
}
