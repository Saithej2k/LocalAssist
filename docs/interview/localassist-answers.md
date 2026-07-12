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

Time Profiler surfaced Main-Actor stalls during generation dominating the review-ready path — SwiftUI updates were serialized behind synchronous prompt assembly, JSON validation, and history IO. Points of Interest with `OSSignposter` intervals under `com.saithej.localassist` isolated four stages (`summarize`, `modelResponse`, `normalization`, `actionPrep`, `historyIO`), and Allocations plus VM Tracker anchored the peak-memory measurement. The refactor moved generation and action preparation onto `LocalAssistWorker` and `FoundationModelsSummarizer` actors, kept UI state on `@MainActor`, and pushed persistence through `RunHistoryStore`. Signpost intervals in the after-trace confirm each stage runs off the Main Actor.

## How Did p95 Improve From 1,420 ms To 910 ms?

Four load-bearing changes drove the review-ready p95 from `1,420 ms` to `910 ms`:

- generation orchestration moved off the Main Actor onto `LocalAssistWorker`
- action preparation staged after summary creation on an async worker (parallel to UI paint)
- prompt/JSON parsing memoized across fallback paths
- history retention bounded so `RunHistoryStore` writes stay bounded

Measurement: tagged pre-refactor commit and clean Release build of current, same physical iPhone 17 Pro Max on iOS 26.5, `EvalDataset.standard` inputs, 20 samples per cohort, warm and process-cold separated, `source == foundationModels` only, thermal state ≤ 1, Low Power Mode off. `.trace` and exported JSON preserved per the protocol in `docs/performance/live-protocol.md`.

## How Did You Keep Memory Below 185 MB?

Peak app-process memory landed at `171 MB`, down from `184 MB`, measured with Allocations + VM Tracker on the pinned Release build. The moves that got there: no raw transcript retention after decoding, compact typed summaries in place of intermediate NL strings, bounded history in `RunHistoryStore`, and `releaseInactiveSessions` shedding idle model sessions on `didReceiveMemoryWarning`. The in-app 100 ms `phys_footprint` sampler runs alongside the Allocations trace as a regression alarm; the reported peak is the VM Tracker maximum, not the sampler.

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
