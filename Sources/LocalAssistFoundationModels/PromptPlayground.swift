// WWDC "Code-Along" recipe for iterating on prompts: import Playgrounds and
// wrap experimental invocations in `#Playground` so the Xcode canvas re-runs
// them the moment you tweak an instruction, a Guide description, or a
// GenerationOptions value.
//
// This file is gated behind `canImport(Playgrounds)` so the package still
// builds on the CLI toolchain, and behind macOS/iOS 26 because the API is
// only vended by the current Xcode SDK.

#if canImport(Playgrounds) && (os(macOS) || os(iOS))
    import FoundationModels
    import Playgrounds

    @available(macOS 26.0, iOS 26.0, *)
    #Playground {
        let session = LanguageModelSession {
            "You are LocalAssist, a private on-device task assistant."
            "Turn raw notes into a headline, 3-5 key points, and up to 5 tasks."
        }

        // Swap the note to test how the model handles new phrasings.
        let response = try await session.respond(
            to: "Call Mom tonight, pick up the birthday cake Saturday morning, and book a dentist appointment for next week.",
            generating: DailyBrief.self,
            includeSchemaInPrompt: true
        )
        print(response.content.headline)
        for task in response.content.tasks {
            print("- \(task.title) (\(task.dueDate ?? "no date"))")
        }
    }
#endif
