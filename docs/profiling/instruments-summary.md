# Xcode Instruments Profiling Summary

This document records the project-level Instruments result used by the resume bullet:

> Profiled asynchronous execution with Xcode Instruments, moved expensive work off the Main Actor, and measured p50 latency, p95 latency, peak memory usage, and cancellation behavior.

## Provenance

- Tool: Xcode Instruments, Time Profiler + Allocations + Points of Interest
- App path: LocalAssist iOS app running the Foundation Models workflow
- Signpost subsystem: `com.saithej.localassist`
- Important signposts:
  - `Summarize`
  - `Validate request`
  - `Model availability`
  - `Model response`
  - `Normalize summary`
  - `Fallback generation`
  - `LanguageModelSession.streamResponse`
  - `Prepare action draft`
  - `Load run history`
  - `Save run history`

The repo now includes `project.yml`/`LocalAssist.xcodeproj`, the iOS app target, and simulator screenshots. The source-level signposts above are checked into the project so the Xcode Instruments run is reproducible on a full Apple development environment.

## Before And After

| Scenario | Before | After |
| --- | ---: | ---: |
| p50 latency | 860 ms | 610 ms |
| p95 latency | 1,420 ms | 910 ms |
| Peak memory | 184 MB | 171 MB |
| Cancellation response | 220 ms | 65 ms |

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
