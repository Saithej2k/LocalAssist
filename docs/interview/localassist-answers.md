# LocalAssist Interview Answers

## What Does LocalAssist Do On Device?

LocalAssist turns local text such as meeting notes or email drafts into a structured summary, key points, suggested tasks, and confirmation-first action drafts. The text stays on device. If Foundation Models is available, the app uses Apple’s on-device model. If it is unavailable, malformed, cancelled, or offline, the app uses a deterministic local fallback.

## How Did You Use Foundation Models?

I isolated Foundation Models behind `StructuredModelClient`. The live adapter checks `SystemLanguageModel.default.availability`, then streams `LanguageModelSession.streamResponse(to:generating: DailyBrief.self)`. The rest of the app receives typed `StructuredSummaryPartial` snapshots and never imports FoundationModels from the view layer.

## What Is Guided Generation?

Instead of asking for free-form prose, LocalAssist uses native guided generation with `@Generable` `DailyBrief` and `BriefTaskSuggestion` types. The contract is `headline`, `keyPoints`, and `tasks`, with optional ISO-8601 due dates. Constrained decoding means there is no JSON extraction, regex repair, or malformed-output cleanup path.

## What Did You Mean By Tool Calling?

The model gets one read-only tool: `CalendarAvailabilityTool`. It checks an actor-isolated sample agenda store through the `FreeBusyProviding` protocol, so the model can avoid colliding due dates without getting write access. EventKit can replace the sample provider later without changing the Tool conformance. Any write-like result is still staged as a draft and requires user confirmation.

## How Did You Handle Streaming And Cancellation?

The app has a stream-first generation path:

- `StructuredModelClient.streamSummary(for:)` exposes engine-agnostic `StructuredSummaryPartial` snapshots.
- `FoundationModelsSummarizer` maps `LanguageModelSession.streamResponse(to:generating:)` snapshots into headline/key point/task partials.
- `LocalAssistService.streamSummary(_:)` emits validation, availability, model streaming, fallback, normalizing, and completed phases.
- SwiftUI stores partial text in transient state and only commits `StructuredSummary` after guided JSON validation succeeds.
- Cancellation is owned by a cancellable SwiftUI `Task`; the service, fallback generation, static test clients, and action preparation call `Task.checkCancellation()`.
- XCTest covers both delayed final-response cancellation and delayed streaming cancellation.

Cancellation propagates as `CancellationError` for the final `summarize(_:)` API. For streaming consumers, the consuming task checks cancellation after stream termination, which prevents a cancelled stream from being mistaken for a completed summary.

## What Went Wrong With Swift Concurrency Initially?

The first issues were classic Swift 6 strict-concurrency problems:

- mutable static App Intents metadata was rejected
- XCTest async assertions could not put `await` inside assertion autoclosures
- metric initialization captured `self` before all stored properties were initialized
- too much orchestration initially lived close to the `@MainActor` view model

The final structure keeps UI state on `@MainActor`, routes generation/action work through `LocalAssistWorker`, streams partial updates into transient UI state, and persists run history through `RunHistoryStore`.

## What Did Instruments Show?

Instruments showed the p95 tail was dominated by work serialized near the UI path: model response handling, guided JSON validation, action draft preparation, and persistence all appeared around the same interaction window. Points of Interest signposts made it clear which phases were taking time.

The fix was to keep the Main Actor responsible for published UI state only and move generation, action preparation, and history IO into async worker/actor boundaries.

## How Did p95 Improve From 1,420 ms To 910 ms?

The p95 reduction came from:

- moving generation orchestration off the Main Actor
- staging action preparation after summary creation on an async worker
- avoiding repeated prompt/JSON parsing on fallback paths
- bounding retained history
- measuring and cancelling long-running work explicitly

The Instruments summary is in `docs/profiling/instruments-summary.md`.

## How Did You Keep Memory Below 185 MB?

The app avoids retaining raw transcripts after decoding, stores compact typed summaries, bounds local history retention, and records memory through benchmark/Allocations passes. The Instruments profile kept peak memory under 185 MB; the recorded after value was 171 MB.

## How Would This Change Across iPhone, Watch, And Vision Pro?

The core stays shared:

- `LocalAssistCore`
- `LocalAssistFoundationModels`
- `LocalAssistAppIntents`
- metrics/history/action-prep models

The UI changes by device:

- iPhone: full editor, summary, history, and action drafts
- Watch: top summary, top task, and reminder confirmation
- Vision Pro: larger spatial workspace with multiple note sources and grouped task cards

## How Do You Test Model-Unavailable And Offline Fallback?

The app injects `StructuredModelClient`, so tests pass deterministic clients that return unavailable states, generation failures, delayed responses, or valid guided snapshots. Coverage includes malformed input, model availability, guardrail/context/decoding fallback, concurrent requests, cancellation, offline execution, frozen-clock deterministic fallback, ISO due-date parsing, run metrics, action preparation, metric distributions, and history persistence.
