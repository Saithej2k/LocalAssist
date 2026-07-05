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

The local CLI baseline measures deterministic fallback performance for repeatable CI. It is not the same measurement as the 1,420 ms to 910 ms Foundation Models Instruments profile.
