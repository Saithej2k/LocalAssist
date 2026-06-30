# LocalAssist

LocalAssist is an on-device intelligent task assistant for Apple platforms. It turns messy notes, emails, and meeting transcripts into structured summaries, prioritized task suggestions, and draft system actions without requiring a network connection.

The project is built as a Swift Package so the core workflow, SwiftUI app surface, Foundation Models adapter, App Intents integration, CLI, benchmarks, and tests can all be verified from source.

## iOS Screenshots

![LocalAssist home](docs/screenshots/01-assistant-home.png)

![Structured summary](docs/screenshots/02-structured-summary.png)

![Action drafts and metrics](docs/screenshots/03-action-drafts-metrics.png)

## Highlights

- Uses the local Foundation Models framework when it is available on the device.
- Falls back to a deterministic offline summarizer when the model is unavailable, cancelled, or produces malformed output.
- Guides output into a strict JSON contract before normalizing the result into typed Swift models.
- Produces tool-assisted action drafts for reminders, calendar holds, and follow-up messages.
- Ships a SwiftUI iOS app surface with model availability, offline fallback, cancellation, structured results, action drafts, and run metrics.
- Includes XCTest coverage for malformed inputs, availability checks, concurrent requests, cancellation, offline execution, and deterministic fallback behavior.
- Includes a benchmark harness and Instruments workflow notes for p50 latency, p95 latency, peak memory, and cancellation behavior.

## Quick Start

```bash
swift test
swift run localassist-selftest
swift run localassist --text "Review the onboarding doc, send Mira the blockers by Friday, and schedule a design sync next week."
swift run localassist-bench --iterations 30
node Tools/Screenshots/render-screenshots.js
```

## Package Layout

- `LocalAssistCore`: validation, guided generation, fallback summarization, tool drafts, and workflow orchestration.
- `LocalAssistFoundationModels`: adapter around Apple's on-device `LanguageModelSession`.
- `LocalAssistAppIntents`: system integration through App Intents.
- `LocalAssistAppUI`: reusable SwiftUI surface for the iOS app.
- `LocalAssistCLI`: local demo executable.
- `LocalAssistBenchmarks`: lightweight latency and cancellation harness.
- `LocalAssistCoreTests`: deterministic XCTest suite.

## Apple Readiness

See [docs/apple-readiness.md](docs/apple-readiness.md) for a point-by-point implementation map and [docs/performance/2026-06-30-baseline.md](docs/performance/2026-06-30-baseline.md) for the latest local benchmark.

## Example

```json
{
  "overview": "Review onboarding material, send blockers, and schedule a design sync.",
  "keyPoints": [
    "Review the onboarding doc",
    "Send Mira the blockers by Friday",
    "Schedule a design sync next week"
  ],
  "suggestions": [
    {
      "title": "Send Mira the blockers",
      "priority": "high",
      "action": "messageDraft",
      "dueHint": "Friday"
    }
  ]
}
```

## Instruments

See [docs/instrumentation.md](docs/instrumentation.md) for the profiling workflow and measurement template.
