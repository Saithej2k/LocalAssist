# Xcode Instruments Claim Status

## Current status

The numerical Instruments resume bullet is **unsupported**. Do not present
the values below as measured project results until the evidence gate in this
document is satisfied.

The old notes contain this draft target:

| Metric | Before | After |
| --- | ---: | ---: |
| p50 total latency | 860 ms | 610 ms |
| p95 total latency | 1,420 ms | 910 ms |
| Peak app-process memory | 184 MB | 171 MB |
| Cancellation response | 220 ms | 65 ms |

Those values are not claim-ready because the original session did not retain:

- the `.trace` files or screenshots;
- exact before and after commit SHAs;
- exact device and iOS build;
- a fixed, saved input set and context-length distribution;
- at least 20 source-pure samples for each reported p95;
- separate cold and warm cohorts;
- a tagged pre-refactor build.

Approximately ten mixed warm/cold runs and unsaved inputs cannot support a
p95 comparison. The values above remain a target for re-measurement, not a
result to optimize toward or reproduce artificially.

## What is implemented

- `OSSignposter` intervals under `com.saithej.localassist` cover summarize,
  validation, availability, model response, normalization, fallback, action
  preparation, and history IO.
- `LocalAssistViewModel` owns UI state on `@MainActor`; generation and action
  preparation run through `LocalAssistWorker`, model work through
  `FoundationModelsSummarizer`, and persistence through `RunHistoryStore`.
- The debug device harness records TTFT, generation completion, review-ready
  latency, source, typed fallback category, cohort, device/build provenance,
  power, thermal state, and periodic `phys_footprint` observations.
- Warm and process-cold campaigns reject dirty or missing SHAs, wrong-source
  fallbacks, failures, incomplete sample counts, thermal pressure, Low Power
  Mode, and changed pinned environments.
- The Xcode build stamps `LocalAssistCommitSHA` into the processed product
  plist. Dirty worktrees receive a `-dirty` suffix and cannot be claim-ready.

These implementation facts support the architecture story. They do not, by
themselves, support a numerical performance result.

## Evidence gate for a replacement claim

1. Pin a tagged pre-refactor commit and the current clean commit.
2. Build both in Release with the same Xcode version.
3. Use the same physical iPhone, iOS build, Apple Intelligence settings, and
   fixed `EvalDataset.standard` inputs.
4. Keep Low Power Mode off and accept only nominal/fair thermal samples.
5. Separate process-cold and warm cohorts. Include only
   `source == foundationModels`; report fallbacks and failures separately.
6. Collect at least 20 valid samples for every p95 being quoted. Use 20 per
   case when reporting per-case p95, or label a 20-launch result aggregate.
7. Define the latency precisely: TTFT, generation completion, or review-ready
   total. The old draft intended review-ready total, not TTFT.
8. Save the exported JSON and the Time Profiler + Points of Interest `.trace`
   files for both builds.
9. Save Allocations + VM Tracker traces for the true app-process peak. The
   in-app 100 ms sampler can miss short spikes and cannot prove `171 MB`.
10. Publish the actual result, even if it is slower than 910 ms or above
    185 MB. Then update the resume to the observed values and conditions.

Use [the live device protocol](../performance/live-protocol.md) for cohort
collection and [the Instruments protocol](../performance/instruments-protocol.md)
for trace capture. A defensible final bullet should name the metric, device,
cohort, N, fixed input set, and build comparison.

## CLI baseline is separate

The checked-in CLI benchmark measures the deterministic fallback path for
repeatable CI coverage:

```bash
swift run -c release localassist-bench --iterations 100 --warmup 5 --concurrency 4 --json --output docs/performance/<date>-benchmark.json
```

It cannot validate Foundation Models latency, Main Actor behavior in the iOS
app, or iPhone VM Tracker peak memory.
