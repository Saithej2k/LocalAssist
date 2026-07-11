import LocalAssistAppIntents
import LocalAssistAppUI
import LocalAssistCore
import SwiftUI

@main
struct LocalAssistApp: App {
    @Environment(\.scenePhase) private var scenePhase

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
