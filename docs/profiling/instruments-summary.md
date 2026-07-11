# Xcode Instruments Profiling Summary

The Instruments session behind the résumé bullet:

> Profiled Swift concurrency with Xcode Instruments and moved expensive work off the Main Actor, reducing p95 response latency from 1,420 ms to 910 ms while keeping peak memory usage below 185 MB.

## Instruments configuration

- Tool: Xcode Instruments — Time Profiler + Allocations + Points of Interest.
- Signpost subsystem: `com.saithej.localassist`.
- Signposts read: `Summarize`, `Validate request`, `Model availability`, `Model response`, `Normalize summary`, `Fallback generation`, `LanguageModelSession.streamResponse`, `Prepare action draft`, `Load run history`, `Save run history`.

The signposts above are still in the source (`Sources/LocalAssistCore/Instrumentation.swift`), and `project.yml` / `LocalAssist.xcodeproj` reproduce the exact target the session profiled.

## Before And After

| Scenario | Before | After |
| --- | ---: | ---: |
| p50 latency | 860 ms | 610 ms |
| p95 latency | 1,420 ms | 910 ms |
| Peak memory | 184 MB | 171 MB |
| Cancellation response | 220 ms | 65 ms |

- **Latency** is the wall-clock duration of the `Summarize` signpost — Generate tap through completed brief usable in the review UI. Not time-to-first-token; not time-to-first-partial.
- **Peak memory** is app-process peak reported by Allocations + VM Tracker across the Smart-brief pass. Both configurations stayed under the 185 MB envelope.
- **Cancellation response** is Cancel tap through the last downstream state mutation gated behind `Task.checkCancellation` — measured with the same `OSSignposter` subsystem.
- **p95** is the 95th percentile of sorted per-run `Summarize` durations, computed with the same formula `MetricDistribution.percentile` uses today (`Sources/LocalAssistCore/PerformanceMetrics.swift`).

## Conditions of this measurement

The Instruments session behind the numbers above ran before the harness and cold-launch campaign in this repo existed. Stated honestly, so anyone quoting these numbers can quote the provenance too:

| Aspect | State of the record |
| --- | --- |
| Device | Physical iPhone (Foundation Models does not run in the Simulator). Session notes name an iPhone 17 Pro Max — same device the SpeechAnalyzer verification in commit `6d5391f` landed on — but the exact hardware was not written down at profile time. |
| iOS build | iOS 26.x, same window as the SpeechAnalyzer on-device work (iOS 26.5). Specific build number not recorded. |
| Xcode | Xcode 26 from `/Applications/Xcode.app/Contents/Developer` — the toolchain CI still pins today. Specific 26.x not recorded. |
| Build configuration | **Release.** Time Profiler + Allocations were taken with Release optimizations. |
| Commit SHA | Not recorded. The session predates `EvalDataset.standard`, so the commit is between the pre-eval-kit tree and the post-actor-refactor tree. The individual actor-introduction commits (`LocalAssistWorker`, `RunHistoryStore`, `FoundationModelsSummarizer`) are the load-bearing ones. |
| Runs per configuration | "Several repeated runs" per session notes — approximately ten per configuration, not the twenty a defensible p95 needs. |
| Inputs | Notes describe "the mixed brain-dump plus a couple of meeting-note pastes." The style became `EvalDataset.standard` afterwards; the exact strings from the session were not saved. |
| Identical inputs across before + after | Same session, same handful of inputs in each configuration. Run-by-run identity not journaled. |
| Warm / cold mix | Warm-dominant. Prewarm existed at the time; the first run of the session was cold, everything after was warm. Not separated into cohorts. |
| `.trace` files or screenshots | Not preserved. Only this summary and the signposts checked into the source. |
| A tagged "before" commit | Not tagged. The refactor commits are individually visible in the history; there is no single pre-optimization tag. |
| Personally run | Yes — I took every measurement in this table. |

Everything the next re-measurement needs to answer each of those rows from the page it prints on is now in the tree: `RunMetrics` stamps `environment: RunEnvironment` (device, OS, build mode, commit SHA, thermal, Low Power, cold/warm) on every run, `ProcessGenerationRegistry` grounds `Cohort` assignment, `DeviceMeasurementHarness` performs one unmeasured warmup then collects 160 warm samples, `ColdLaunchCampaignStore` envelopes cold statistics, and the app build stamps `LocalAssistCommitSHA` into `Info.plist` via `project.yml postBuildScripts`. The re-run recipe is `docs/performance/live-protocol.md`; the Instruments protocol is `docs/performance/instruments-protocol.md`.

## What Changed

- Moved generation orchestration, action preparation, and history persistence out of the SwiftUI Main Actor path.
- Kept `LocalAssistViewModel` isolated to `@MainActor` for UI state only.
- Added the `LocalAssistWorker` actor for generation/action work.
- Added `RunHistoryStore` as an actor-backed persistence boundary.
- Tightened guided JSON decoding so malformed model output falls into deterministic fallback instead of retrying on the UI path.
- Avoided retaining raw model transcripts after decoding into `StructuredSummary`.
- Limited saved history to a bounded local retention window.

## How To Reproduce

1. Open the package in Xcode 26 or newer.
2. Run `xcodegen generate` and open `LocalAssist.xcodeproj`.
3. Select Product > Profile.
4. Use Time Profiler and add Points of Interest.
5. Filter for subsystem `com.saithej.localassist`.
6. Repeat with Allocations enabled.
7. Exercise:
   - Foundation Models available path
   - forced offline fallback path
   - cancellation while a generation is in flight
   - several repeated runs to populate history metrics

## CLI Baseline

The checked-in CLI benchmark is separate from the Instruments result. It measures the deterministic fallback path for repeatable CI coverage:

```bash
swift run -c release localassist-bench --iterations 100 --warmup 5 --concurrency 4 --json --output docs/performance/2026-07-02-benchmark.json
```

That baseline is intentionally much faster than the live Foundation Models path and should not be confused with the resume p95 number.
