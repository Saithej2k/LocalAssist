# Instruments Collection Protocol (owner-on-device)

Exact steps for the five instruments that matter to LocalAssist, so a
profiling session produces numbers that can be quoted with their conditions
attached. Every session records the header from
[live-protocol.md](live-protocol.md) first: device model, iOS version,
build stamp, thermal state, Low Power Mode.

All collection below **requires the physical iPhone attached to Xcode** and
remains unexecuted until the owner runs it. Nothing in this file is a
measurement.

## Common setup

1. `xcodegen generate`, open `LocalAssist.xcodeproj`, scheme **LocalAssist**,
   Release configuration for latency work (Debug only for Allocations when
   symbol fidelity matters more than speed).
2. Product → Profile (⌘I) with the device selected — never the simulator;
   the on-device model and the ANE do not exist there.
3. Airplane Mode on, screen at fixed brightness, device idle ≥ 2 minutes
   past app install, thermal state nominal before the first sample.
4. Workload: the eight `EvalDataset.standard` inputs, pasted or run via the
   debug measurement harness (Settings → Measurement → Run device
   measurement), 20 repetitions per case — the 160-warm-run floor.

## Cohorts

The harness labels every sample with a fact-based cohort:

- **processCold** — no generation had started in the process before the
  sample (`ProcessGenerationRegistry` was zero). At most one per launch.
- **sessionCold** — first sample on the harness run's fresh service, in a
  process that had already generated.
- **warm** — everything else.

Genuine process-cold statistics need repeated launches. Collect ≥20 with
the cold-launch UI test on the connected phone:

```bash
LOCALASSIST_COLD_LAUNCHES=20 xcodebuild test \
  -project LocalAssist.xcodeproj -scheme LocalAssist \
  -destination 'platform=iOS,name=<your iPhone>' \
  -only-testing:LocalAssistUITests/MeasurementColdLaunchTests
```

Each launch runs exactly one sample as the process's first generation
(launch automation is suppressed for these launches so nothing generates
first) and appends it to a JSONL outbox in Documents; the next Settings
measurement run folds them into its report under
`processColdLaunchSamples`. Failed samples are preserved with their typed
failure category — error rate is part of the measurement — and memory is
sampled continuously (100 ms cadence) for the whole interval, so
between-sample spikes land in `memory.peakMB`.

## Time Profiler

- Template: **Time Profiler**. Add the **os_signpost** instrument alongside.
- Filter signposts to subsystem `com.saithej.localassist`. The generation
  path emits `Summarize`, `Validate request`, `Model availability`,
  `Model response`, `Normalize summary`, `Fallback generation`,
  `Route command`; the voice path emits `MicStart` and `StopDrain`.
- Read: time-to-first-partial and full-generation intervals per signpost;
  main-thread samples inside `Model response` should be ~zero (streaming is
  off-main; only `@Published` mutation lands on main).
- Record p50/p95 per interval across the 20 runs, cold and warm cohorts
  separated.

## Swift Concurrency

- Template: **Swift Concurrency**.
- Verify: no task runs on the main actor during `Model response`; the
  `LocalAssistWorker` actor shows one executor lane; `EventKitWriteStore`
  work appears only around confirmed executions; no continuation is held
  past `StopDrain` end.
- Alert conditions: task explosion during map-reduce chunking (should be
  serial), or an orphaned task after cancellation (tap Cancel mid-run 5×).

## Points of Interest

- Template: **Blank** + add **Points of Interest** + **os_signpost**.
- The voice timeline logs one line per session (`timeline gen=`) with tap
  request → drain completion offsets; correlate with `MicStart`/`StopDrain`
  intervals for the same generation number.
- Read: audio-ready and first-partial offsets across 10 dictation sessions;
  compare against the `VoiceSessionTimeline` snapshot the app logs — the
  two must agree or the timeline instrumentation is wrong.

## Allocations

- Template: **Allocations**, with **VM Tracker** in the same document.
- Mark generation start/end with the `Summarize` signpost; snapshot before
  the first run, after run 1, after run 20.
- Read: persistent-bytes delta between run 1 and run 20 (session leak
  check — the 20-run growth should be flat after the first model session
  is resident); transient spikes during streaming should be released by
  the next mark. Investigate any `AVAudioPCMBuffer` accumulation across
  dictation sessions.
- `autoreleasepool` additions are justified only by growth visible here in
  Objective-C autorelease bins — none are currently in the code because no
  such growth has been demonstrated.

## VM Tracker

- Runs inside the Allocations document; sample every 1s, "track dirty
  memory" on.
- Read: **phys_footprint** (the Jetsam number, same counter the debug
  harness samples) at idle, during streaming, at 20-run steady state, and
  during a dictation session with streaming generation.
- Quote peak footprint with its workload attached ("during streaming brief
  over case `meeting-notes`, warm"), never a bare number.

## Reporting

Date-stamped markdown in `docs/performance/`, one file per session, with
the header, per-instrument readings, and the exported harness JSON attached.
Numbers enter README or interview docs only after they exist in such a file.
