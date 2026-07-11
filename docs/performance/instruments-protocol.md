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

Cohorts are facts, grounded in a process-wide generation registry:

- **processCold** — no generation had started in the process before the
  sample. At most one per launch.
- **sessionCold** — first generation on a fresh service in a process that
  had already generated.
- **warm** — everything else.

The in-app harness runs **one unmeasured session-cold warmup** before
sampling, so its dataset is exactly 8 cases × 20 repetitions of warm
samples — "160 warm runs" with no mislabeled first sample. Cold numbers
never come from that run; they come from a **cold-launch campaign**:

```bash
TEST_RUNNER_LOCALASSIST_COMMIT_SHA=$(git rev-parse --short HEAD) \
TEST_RUNNER_LOCALASSIST_COLD_LAUNCHES=20 \
xcodebuild test \
  -project LocalAssist.xcodeproj -scheme LocalAssist \
  -destination 'platform=iOS,name=<your iPhone>' \
  -only-testing:LocalAssistUITests/MeasurementColdLaunchTests
```

(`xcodebuild` forwards only `TEST_RUNNER_`-prefixed variables. The app
build also stamps `LocalAssistCommitSHA` into its Info.plist via a build
script, so Settings-button runs carry the SHA without any environment.
**A campaign whose environment has no commit SHA is not claim-ready** —
its numbers cannot say which code they measured, and the report's
`claimReady: false` marks them unquotable.)

The in-app harness's warm cohort is equally gated: warm samples exist in
a report only when `warmupOutcome` is `.succeeded` from the
configuration's expected engine. A warmup that failed, or that answered
from the deterministic fallback when the run intended to measure
Foundation Models, aborts the warm cohort — there is no such thing as a
"warm model sample" the model never produced.

The first launch resets and begins a campaign — an envelope pinning
campaign ID, timestamp, device, OS, build configuration, commit SHA, and
the expected generation source. Each launch runs exactly one sample as
the process's first generation (launch automation is suppressed so
nothing generates first), classifies it against the expected source
(a deterministic-fallback answer in a Foundation Models campaign is
recorded as `unexpectedSource`, never counted as a cold model sample),
and appends the record durably — fsync before the UI-test completion
marker appears, so a failed write fails the launch loudly. Failures are
campaign records too, with their typed category. Reports embed only the
active campaign's records; different campaigns never fold together.

**Statistics honesty:** 20 cold launches support an *aggregate* cold p95
only. For per-case cold percentiles run 20 launches per case
(`LOCALASSIST_COLD_LAUNCHES=160` over the 8-case dataset).

**Memory:** the harness does 100 ms periodic footprint sampling — not a
continuous record. A spike shorter than the sampling interval can be
missed; claim a true peak only from Instruments (Allocations + VM
Tracker, below).

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
