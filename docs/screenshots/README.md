# iOS Screenshots

The root PNGs in this folder are deterministic iPhone-sized screenshots generated from `Tools/Screenshots/render-screenshots.js`.

They mirror the SwiftUI surface in `LocalAssistAppUI`, including input, structured output, action drafts, run metrics, local history, and aggregate performance. A full Xcode installation can replace these with simulator captures from the real app target.

The `simulator/` folder contains real iOS 26.5 simulator captures from `LocalAssist.xcodeproj`:

- `01-home.png`: launched app with Foundation Models availability.
- `02-live-streaming.png`: live `LanguageModelSession.streamResponse(to:)` partial guided JSON.
- `03-live-summary.png`: validated structured summary and staged action drafts after generation.
