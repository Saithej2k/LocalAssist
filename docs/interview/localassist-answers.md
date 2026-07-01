# LocalAssist Interview Answers

## What Does LocalAssist Do On Device?

LocalAssist turns local text such as meeting notes or email drafts into a structured summary, key points, suggested tasks, and confirmation-first action drafts. The text stays on device. If Foundation Models is available, the app uses Apple’s on-device model. If it is unavailable, malformed, cancelled, or offline, the app uses a deterministic local fallback.

## How Did You Use Foundation Models?

I isolated Foundation Models behind `LanguageModelClient`. The live adapter checks `SystemLanguageModel.default.availability`, then calls `LanguageModelSession().respond(to:)`. The rest of the app receives typed `StructuredSummary` output and does not depend directly on Foundation Models APIs.

## What Is Guided Generation?

Instead of asking for free-form prose, LocalAssist prompts the model to return a strict JSON contract with `overview`, `keyPoints`, and `suggestions`. The app extracts the JSON object, decodes it into Swift types, clamps suggestion counts, validates action types, and falls back deterministically if decoding fails.

## What Did You Mean By Tool Calling?

The app does not let the model perform system writes directly. It maps suggested tasks into tool-action drafts:

- reminder
- calendar hold
- message draft
- checklist item

Each draft is staged by `DraftOnlyToolActionPreparer` and requires user confirmation before any future integration writes to Reminders, Calendar, or Messages.

## How Did You Handle Streaming And Cancellation?

The current implementation uses async response generation, not token streaming. Cancellation is handled through Swift structured concurrency:

- SwiftUI owns a cancellable `Task`.
- `LocalAssistService`, fallback generation, static test clients, and action preparation call `Task.checkCancellation()`.
- Cancellation propagates as `CancellationError`.
- Tests use delayed model clients to verify cancellation paths.

If streaming were added, I would stream partial text into a transient UI state and only commit a final result after JSON validation succeeds.

## What Went Wrong With Swift Concurrency Initially?

The first issues were classic Swift 6 strict-concurrency problems:

- mutable static App Intents metadata was rejected
- XCTest async assertions could not put `await` inside assertion autoclosures
- metric initialization captured `self` before all stored properties were initialized
- too much orchestration initially lived close to the `@MainActor` view model

The final structure keeps UI state on `@MainActor`, routes work through `LocalAssistWorker`, and persists run history through `RunHistoryStore`.

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

The app injects `LanguageModelClient`, so tests pass deterministic clients that return unavailable states, malformed JSON, delayed responses, or valid guided JSON. Coverage includes malformed input, model availability, malformed model output, concurrent requests, cancellation, offline execution, deterministic fallback, run metrics, action preparation, metric distributions, and history persistence.
