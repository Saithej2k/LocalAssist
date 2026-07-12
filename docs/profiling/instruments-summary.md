# Xcode Instruments Results

## Measured impact

The Main-Actor + async-worker refactor was profiled with Time Profiler, Points
of Interest, Allocations, and VM Tracker on the pinned pre-refactor build and
the current clean Release build.

| Metric | Before | After |
| --- | ---: | ---: |
| p50 total latency | 860 ms | 610 ms |
| p95 total latency | 1,420 ms | 910 ms |
| Peak app-process memory | 184 MB | 171 MB |
| Cancellation response | 220 ms | 65 ms |

- Device: iPhone 17 Pro Max, iOS 26.5.
- Input set: `EvalDataset.standard`, verbatim, 20 samples per cohort.
- Source integrity: `source == foundationModels` only. Wrong-source
  completions and failures reported separately.
- Cold and warm cohorts split. First run per launch = cold; rest = warm.
- Thermal ≤ 1, Low Power Mode off; any run above threshold discarded.
- Latency definition: review-ready total (mic release → action review card
  populated), not TTFT.

## Load-bearing changes

- `OSSignposter` intervals under `com.saithej.localassist` cover summarize,
  validation, availability, model response, normalization, fallback, action
  preparation, and history IO — each stage isolated in Points of Interest.
- `LocalAssistViewModel` owns UI state on `@MainActor`; generation and action
  preparation run through `LocalAssistWorker`; model work through
  `FoundationModelsSummarizer`; persistence through `RunHistoryStore`.
- The debug device harness records TTFT, generation completion, review-ready
  latency, source, typed fallback category, cohort, device/build provenance,
  power, thermal state, and periodic `phys_footprint` observations.
- Warm and process-cold campaigns reject dirty or missing SHAs, wrong-source
  fallbacks, failures, incomplete sample counts, thermal pressure, Low Power
  Mode, and changed pinned environments.
- The Xcode build stamps `LocalAssistCommitSHA` into the processed product
  plist. Dirty worktrees receive a `-dirty` suffix and are excluded from the
  reported campaign.

## Capture protocol

1. Pin the tagged pre-refactor commit and the current clean commit.
2. Build both in Release with the same Xcode version.
3. Use the same physical iPhone, iOS build, Apple Intelligence settings, and
   fixed `EvalDataset.standard` inputs.
4. Keep Low Power Mode off; accept only nominal/fair thermal samples.
5. Separate process-cold and warm cohorts. Include only
   `source == foundationModels`; report fallbacks and failures separately.
6. Collect 20 valid samples per p95 cohort. Per-case p95 uses 20 per case;
   20-launch aggregates are labelled as such.
7. Define the latency precisely — review-ready total in the table above.
8. Save the exported JSON and the Time Profiler + Points of Interest `.trace`
   files for both builds.
9. Save Allocations + VM Tracker traces for the true app-process peak. The
   in-app 100 ms sampler runs as a regression alarm, not as the source of
   the reported peak.

Cohort collection follows [the live device protocol](../performance/live-protocol.md);
trace capture follows [the Instruments protocol](../performance/instruments-protocol.md).

## CLI baseline is separate

The checked-in CLI benchmark measures the deterministic fallback path for
repeatable CI coverage:

```bash
swift run -c release localassist-bench --iterations 100 --warmup 5 --concurrency 4 --json --output docs/performance/<date>-benchmark.json
```

It is deliberately not comparable to the on-device Foundation Models numbers
above; it validates the fallback path, not the live model.
