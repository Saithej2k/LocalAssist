import LocalAssistAppIntents
import LocalAssistAppUI
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
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                return
            }
            Task {
                // Keep briefs searchable from Spotlight (and eligible for
                // Siri personal context) — donation is local-only.
                await LocalAssistSpotlight.donateAll()
            }
        }
    }
}
