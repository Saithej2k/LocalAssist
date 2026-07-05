# local assist

local assist is an offline-first command center for notes, voice captures, meetings, and personal admin. It turns messy input into a concise brief, prioritized task suggestions, reminders, calendar candidates, and draft system actions, with a Go Online button for the Apple Foundation Models path.

The project is built as a Swift Package so the core workflow, SwiftUI app surface, Foundation Models adapter, App Intents integration, CLI, benchmarks, and tests can all be verified from source.

## iOS Screenshots

![local assist home](docs/screenshots/01-assistant-home.png)

![Structured summary](docs/screenshots/02-structured-summary.png)

Real iOS 26.5 simulator captures are in [`docs/screenshots/simulator`](docs/screenshots/simulator), including the capture-first home screen, an instant brief with the editable action review, a live Foundation Models streaming pass, and the final validated summary state.

![Capture-first home (simulator)](docs/screenshots/simulator/04-capture-first-home.png) Current working captures from this build are in `outputs/localassist-working-screenshots`.

## Highlights

- **Real guided generation**: `DailyBrief` / `BriefTaskSuggestion` `@Generable` types with `streamResponse(generating:)` — constrained decoding guarantees schema conformance, so there is no JSON-repair path anywhere in the app.
- **Typed streaming UI**: `PartiallyGenerated` snapshots map to typed partials; the headline renders within the first snapshots while key points and tasks are still generating.
- **Offline-first with Go Online**: the app starts on deterministic local generation; tapping Go Online enables the Apple Foundation Models adapter and prewarms the session.
- **Session reuse + `prewarm()`**: one `LanguageModelSession` serves consecutive online turns, the schema is dropped from repeat prompts (`includeSchemaInPrompt: false`), and the model is prewarmed when online mode is enabled.
- **Command-center capture modes**: the app routes Notes, Voice, Meeting, and Admin inputs through the same engine, with mode-specific Foundation Models prompting.
- **Polished Voice Notes to Tasks**: the iOS app uses microphone capture plus on-device Speech recognition where available, shows a live transcript surface, then feeds the transcript into the local brief/action pipeline.
- **Today + Action Review**: Today summarizes due items, next actions, and capture history; Action Review lets users edit action type, title, date, and notes before anything is written or opened.
- **Real tool calling**: `CalendarAvailabilityTool` conforms to the Foundation Models `Tool` protocol and is backed by an actor-isolated sample agenda store; an EventKit provider can be swapped in later without changing the tool conformance.
- **Executable actions with confirmation**: confirmed drafts write actual `EKReminder`s and `EKEvent` holds through a testable `SystemWriteStore` seam, with a deterministic natural-language due-date parser.
- **Typed error taxonomy**: `guardrailViolation`, `refusal`, `exceededContextWindowSize`, `unsupportedLanguage`, and each `UnavailableReason` map to distinct diagnostics. The deterministic offline fallback substitutes for generation failures so the app never dead-ends.
- **Context-window management**: rolling-window + summarization compression (`ConversationMemory`); on projected or actual transcript overflow the session is rebuilt with a condensed digest and retried. Follow-up "refine" turns reuse the live session.
- **Siri-grade App Intents**: `AssistantRunEntity` (AppEntity) lets Shortcuts chain summaries into other apps; reminder creation confirms via an interactive snippet (`SnippetIntent`) in Siri/Spotlight before any system write.
- **Eval harness**: `localassist-eval` scores task recall, due-hint accuracy, action mapping, structure compliance, and hallucination probes over a fixed dataset — deterministic, CI-gated, tracked in `docs/evals` alongside latency baselines.
- **Private benchmark workflow**: p50–p99 latency, throughput, peak memory, fallback rate, and cancellation timing stay in developer docs/benchmarks, not on the user-facing app screen.

## Quick Start

```bash
# Use the full Xcode toolchain: plain CommandLineTools builds but silently skips XCTest.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift test
swift run localassist-selftest
swift run localassist-eval --output docs/evals --min-score 0.9   # add --live on an Apple Intelligence device
swift run localassist --text "Review the onboarding doc, send Mira the blockers by Friday, and schedule a design sync next week."
swift run localassist-bench --iterations 100 --warmup 5 --concurrency 4 --json --output docs/performance/latest.json
node Tools/Screenshots/render-screenshots.js
xcodegen generate
env -u LD -u LDFLAGS xcodebuild -project LocalAssist.xcodeproj -scheme LocalAssist -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' CODE_SIGNING_ALLOWED=NO build
```

## Physical iPhone Testing

You can install directly to your own iPhone from Xcode with a free Apple Account / Personal Team. A paid Apple Developer Program membership is only needed for TestFlight, App Store distribution, and broader signing/distribution workflows.

Use an Apple Intelligence-capable iPhone on iOS 26, turn on Apple Intelligence & Siri, then run the `LocalAssist` scheme with your phone selected as the destination. Voice mode will ask for microphone and speech-recognition permission on first use. The simulator is still useful for UI, typed input, and fallback verification, but real on-device model and microphone behavior should be checked on your phone.

## Package Layout

- `LocalAssistCore`: platform-agnostic orchestration — validation, typed streaming partials, `GenerationFailure` taxonomy, brief normalization, deterministic fallback, ISO due-date parsing, conversation memory, action drafts/execution seams, run history, and metrics.
- `LocalAssistFoundationModels`: the on-device adapter — `DailyBrief` `@Generable` contract, `FoundationModelsSummarizer` actor (session reuse, prewarm, typed streaming, overflow recovery, error mapping).
- `LocalAssistSystemTools`: Foundation Models calendar `Tool` conformance backed by a sample agenda actor plus the EventKit-backed `SystemActionExecutor` for confirmed writes.
- `LocalAssistAppIntents`: `AssistantRunEntity`, App Shortcuts phrases, and intents with interactive-snippet confirmation.
- `LocalAssistAppUI`: SwiftUI surface — offline/online mode control, Today view, polished voice capture, typed streaming skeleton, editable Action Review, same-session refinement, and history.
- `LocalAssistEvalKit` / `localassist-eval`: fixed dataset, deterministic scorers, dated JSON+markdown reports, CI threshold gate.
- `LocalAssistCLI`: local demo executable.
- `LocalAssistBenchmarks`: latency, throughput, memory, and cancellation harness.
- `LocalAssistCoreTests`: deterministic XCTest suite (34 tests) covering the fallback policy, error taxonomy, streaming, cancellation, tools, executor, memory, eval scorers, capture modes, frozen-clock due dates, and `XCTClockMetric` fallback latency.

## Apple Readiness

See [docs/apple-readiness.md](docs/apple-readiness.md) for a point-by-point implementation map, [docs/performance/2026-07-02-baseline.md](docs/performance/2026-07-02-baseline.md) for the latest local benchmark summary, and [docs/performance/2026-07-02-benchmark.json](docs/performance/2026-07-02-benchmark.json) for machine-readable telemetry.

## Example

```json
{
  "headline": "Review onboarding material, send blockers, and schedule a design sync.",
  "keyPoints": [
    "Review the onboarding doc",
    "Send Mira the blockers by Friday",
    "Schedule a design sync next week"
  ],
  "tasks": [
    {
      "title": "Send Mira the blockers",
      "priority": "high",
      "dueDate": "2026-07-03"
    }
  ]
}
```

## Output-Quality Evals

`localassist-eval` runs a fixed dataset through the pipeline and scores task recall, due-hint accuracy, action mapping, structure compliance, and hallucination probes with deterministic reference-based scorers (no LLM judge, so scores are reproducible and CI-gateable). Reports land in [docs/evals](docs/evals) as dated JSON + markdown so quality is tracked over time next to the latency baselines. Run with `--live` on an Apple Intelligence device to compare the on-device model against the deterministic fallback on the same dataset.

## Instruments

See [docs/instrumentation.md](docs/instrumentation.md) for the profiling workflow and [docs/profiling/instruments-summary.md](docs/profiling/instruments-summary.md) for the Xcode Instruments summary behind the 1,420 ms to 910 ms p95 optimization.
