# Live Foundation Models Latency Protocol

The original Instruments comparison (p95 1,420 ms → 910 ms) is a before/after
from one profiling session, and its summary now states plainly what it did
not record: exact inputs, run count, warm/cold mix, device. This protocol is
what a re-run pins, so the next number can answer every one of those
questions from the page it is printed on.

## Protocol

1. **Device**: record model, iOS version, and build stamp in the baseline
   header. One device per baseline; numbers from different hardware never
   share a table.
2. **Input set**: the eight cases of `EvalDataset.standard`, verbatim — the
   same fixed dataset the quality evals score, so latency and accuracy
   baselines describe the same workload.
3. **Run count**: 20 runs per case minimum before quoting a p95. Percentiles
   from fewer runs go in the notes, never the headline.
4. **Cold/warm split**: the first run after a fresh app launch is the cold
   sample; every subsequent run in that launch is warm. Report the two
   populations separately — mixing them is how a p95 stops meaning anything.
5. **Thermal and power state**: log `ProcessInfo` thermal state and Low
   Power Mode per run, the way every voice session already does
   (`thermal=`, `lowPower=`). Discard runs above thermal state 1 or note
   them explicitly.
6. **Collection**: on-device runs land in `RunHistoryStore` with per-run
   `durationMilliseconds` and `source`; Settings → Export history (JSON)
   carries them off the phone. `AggregateRunMetrics` computes the p50/p95
   split by source. No hand-copied numbers.
7. **Report**: date-stamped markdown in `docs/performance`, same shape as
   the CLI baselines, with the device header from step 1.

## What exists today

- `docs/evals/2026-07-10-eval-live.md` — the live model's quality number
  (mean composite 0.89, minimum 0.85) as a committed record on an M1 Mac,
  clearly not a phone measurement.
- `docs/evals/2026-07-10-speecheval-fallback.md` — the speech front end
  measured end to end (WER 0.07 synthetic, speech task composite 0.93
  against the 1.00 text ceiling), same machine caveat.
- CLI fallback baselines in this directory — deterministic path, CI-grade
  repeatable, deliberately not comparable to the live numbers.

The gap this protocol closes is the phone-side live latency baseline: run
the eight cases per the steps above on the development iPhone, export, and
commit the result next to this file.
