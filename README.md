# LocalAssist

LocalAssist is an on-device intelligent task assistant for Apple platforms. It turns messy notes, emails, and meeting transcripts into structured summaries, prioritized task suggestions, and draft system actions without requiring a network connection.

The project is built as a Swift Package so the core workflow can be tested from the command line while still exposing Apple-platform integration points through Foundation Models and App Intents.

## Highlights

- Uses the local Foundation Models framework when it is available on the device.
- Falls back to a deterministic offline summarizer when the model is unavailable, cancelled, or produces malformed output.
- Guides output into a strict JSON contract before normalizing the result into typed Swift models.
- Produces tool-assisted action drafts for reminders, calendar holds, and follow-up messages.
- Includes XCTest coverage for malformed inputs, availability checks, concurrent requests, cancellation, offline execution, and deterministic fallback behavior.
- Includes a benchmark harness and Instruments workflow notes for p50 latency, p95 latency, peak memory, and cancellation behavior.

## Quick Start

```bash
swift test
swift run localassist-selftest
swift run localassist --text "Review the onboarding doc, send Mira the blockers by Friday, and schedule a design sync next week."
swift run localassist-bench --iterations 30
```

## Package Layout

- `LocalAssistCore`: validation, guided generation, fallback summarization, tool drafts, and workflow orchestration.
- `LocalAssistFoundationModels`: adapter around Apple's on-device `LanguageModelSession`.
- `LocalAssistAppIntents`: system integration through App Intents.
- `LocalAssistCLI`: local demo executable.
- `LocalAssistBenchmarks`: lightweight latency and cancellation harness.
- `LocalAssistCoreTests`: deterministic XCTest suite.

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
