import LocalAssistAppIntents
import LocalAssistAppUI
import SwiftUI

@main
struct LocalAssistApp: App {
    @Environment(\.scenePhase) private var scenePhase

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
