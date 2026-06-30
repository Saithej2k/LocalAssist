# Instrumentation Notes

LocalAssist keeps expensive generation and normalization work off the Main Actor. The command-line benchmark gives a repeatable baseline before deeper Xcode Instruments profiling.

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

1. Open the package in Xcode.
2. Select the `localassist-bench` executable.
3. Profile with the Time Profiler template.
4. Add Allocations to inspect peak memory.
5. Run once with the Foundation Models adapter enabled and once with the deterministic fallback path.
6. Capture cancellation by running the benchmark with `--cancel-after-ms 25`.

## Measurement Template

| Scenario | p50 latency | p95 latency | Peak memory | Cancellation latency | Notes |
| --- | ---: | ---: | ---: | ---: | --- |
| Deterministic fallback |  |  |  |  |  |
| Foundation Models available |  |  |  |  |  |
| Model unavailable fallback |  |  |  |  |  |
| Concurrent 20 requests |  |  |  |  |  |

## Latest Local Baseline

See [2026-06-30-baseline.md](performance/2026-06-30-baseline.md).
