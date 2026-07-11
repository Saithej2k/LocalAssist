# Instrumentation Notes

LocalAssist keeps expensive generation and normalization work off the Main Actor. The command-line benchmark gives a repeatable baseline, while Xcode Instruments captures the live iOS/Foundation Models profile.

See [profiling/instruments-summary.md](profiling/instruments-summary.md) for the resume p95 profile summary.

## Command-Line Baseline

```bash
swift run -c release localassist-bench --iterations 100
```

Record:

- p50 latency
- p75 latency
- p90 latency
- p95 latency
- p99 latency
- peak resident memory
- memory delta
- throughput
- successful cancellation latency
- fallback rate

## Xcode Instruments Workflow

1. Run `xcodegen generate`.
2. Open `LocalAssist.xcodeproj` in Xcode 26 or newer.
3. Run the `LocalAssist` iOS app target.
4. Profile with the Time Profiler template.
5. Add Points of Interest and filter subsystem `com.saithej.localassist`.
6. Add Allocations to inspect peak memory.
7. Run once with the Foundation Models adapter enabled and once with the deterministic fallback path.
8. Capture cancellation by cancelling an in-flight generation.

## Measurement Template

| Scenario | p50 latency | p95 latency | Peak memory | Cancellation latency | Notes |
| --- | ---: | ---: | ---: | ---: | --- |
| Deterministic fallback |  |  |  |  |  |
| Foundation Models available |  |  |  |  |  |
| Model unavailable fallback |  |  |  |  |  |
| Concurrent 20 requests |  |  |  |  |  |

## Latest Local Baseline

See [2026-07-02-baseline.md](performance/2026-07-02-baseline.md).

The local CLI baseline measures the deterministic fallback path for repeatable CI coverage. The Foundation Models Instruments profile — p95 1,420 ms → 910 ms with app-process peak memory under 185 MB — lives in [docs/profiling/instruments-summary.md](profiling/instruments-summary.md) and describes a separate workload (Smart-brief through `SystemLanguageModel`), so the two numbers should be read side by side, not against each other.

## Voice Capture Signposts

`OSSignposter` category `Voice` (subsystem `com.saithej.localassist`) marks two intervals visible in Instruments' Points of Interest:

- `MicStart` — mic tap to recording (permissions, pipeline, audio activation, analyzer start).
- `StopDrain` — mic release to final transcript (the bounded wait for late finals).

Each phase also logs its duration, so Console alone can localize a regression:

```
session started: gen=2, permissions=17ms, pipeline+audio=211ms, total=228ms, thermal=0, lowPower=false
audio up: category=0ms, activate=56ms, engine=154ms
drained: gen=2, transcript=182 chars, confidence=0.87, voiced=0.42, maxPeak=0.412, hint=false
```

Device baseline (iPhone 17 Pro Max, iOS 26.5, 2026-07-07): warm mic start 205–262 ms end to end; cold start after a fresh install is dominated by permission-service reads/prompts (1.2–4.7 s), which launch-time cache warming moves off the tap path.
