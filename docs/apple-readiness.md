# Apple Readiness Map

This document maps the LocalAssist implementation to the product claims in the project brief.

| Claim | Implementation |
| --- | --- |
| On-device structured summaries and task suggestions | `LocalAssistFoundationModels` calls `SystemLanguageModel.default.availability` and `LanguageModelSession.respond(to:)`; `LocalAssistCore` validates the guided JSON into typed `StructuredSummary` and `TaskSuggestion` models. |
| Works without network access | `LocalAssistService` falls back to `DeterministicFallbackGenerator` when no model is configured, unavailable, cancelled, or malformed. The iOS UI exposes a force-offline toggle. |
| Guided generation | `GenerationGuide` builds a strict JSON contract and decodes only valid schema-shaped output before creating typed summaries and drafts. |
| Tool-assisted actions | `ToolActionPlanner` converts suggestions into reminder, calendar, message, and checklist drafts. `DraftOnlyToolActionPreparer` stages actions for explicit confirmation before any system write. |
| System-level integration | `LocalAssistSummaryIntent` exposes the workflow through App Intents, and `LocalAssistShortcuts` publishes Shortcut phrases. |
| Async work off the Main Actor | `LocalAssistAppUI` keeps the SwiftUI view model on the Main Actor and routes generation/action preparation through the `LocalAssistWorker` actor. |
| Xcode Instruments profiling | `OSSignposter` intervals are checked in for generation, Foundation Models response, JSON decode, fallback, action preparation, and history IO. The imported Instruments summary records p95 moving from 1,420 ms to 910 ms. |
| p50/p95/peak memory/cancellation measurement | `localassist-bench` records p50, p75, p90, p95, p99, throughput, peak resident memory, memory delta, fallback rate, and cancellation behavior. The 2026-06-30 baseline is in `docs/performance`. |
| Private run history | `RunHistoryStore` persists local run history as JSON, enforces a retention limit, and computes aggregate p50/p95/source/draft metrics for the app. |
| Automated tests | `LocalAssistCoreTests` and `localassist-selftest` cover malformed input, model availability, malformed model output, concurrent requests, cancellation, offline execution, deterministic fallback, run metrics, action preparation, metric distributions, and history persistence. |
| iOS app surface | `LocalAssistAppUI` contains the SwiftUI app experience and `Apps/iOS/LocalAssist` contains the app entry point and iOS metadata. |
| iOS screenshots | `Tools/Screenshots/render-screenshots.js` generates the checked-in 1290x2796 PNG screenshots in `docs/screenshots`. |
