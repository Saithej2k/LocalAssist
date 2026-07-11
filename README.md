<div align="center">

<img src="docs/branding/localassist-icon.png" width="120" alt="LocalAssist — a sleepy owl hugging a phone. Your thoughts never leave home.">

# LocalAssist

**Say it once. It becomes a plan — right on your phone.**

An offline-first iOS assistant that turns voice notes, meeting notes, and messy text into a
structured brief, prioritized tasks with real due dates, and confirmed Reminders & Calendar
entries. No account. No API key. No network.

[![Swift CI](https://github.com/Saithej2k/LocalAssist/actions/workflows/swift.yml/badge.svg)](https://github.com/Saithej2k/LocalAssist/actions/workflows/swift.yml)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
![iOS 26+](https://img.shields.io/badge/iOS-26%2B-000000?logo=apple&logoColor=white)
![100% on-device](https://img.shields.io/badge/AI-100%25%20on--device-34C759)
[![MIT License](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

<br>

<img src="docs/screenshots/simulator/06-capture-home-dark.png" width="300" alt="Capture home: one text box, mic, and Generate on a Liquid Glass shelf">&nbsp;&nbsp;
<img src="docs/screenshots/simulator/07-action-review-dark.png" width="300" alt="Generated brief with editable action review before anything is written">

</div>

## Why

The moment after you say *"call Mom tonight, grab the birthday cake Saturday, and get the dentist booked before next week"* is where plans go to die. Cloud tools solve this by uploading your voice and your personal life to a server. LocalAssist solves it without letting a single byte leave the device:

- **Private by design** — capture, transcription, and summarization all run on the phone. Airplane mode is a supported configuration, not an error state.
- **Two on-device modes** — *Smart brief* uses Apple's Foundation Models framework with constrained decoding; *Instant brief* uses a deterministic rules engine that works on every device, even where Apple Intelligence doesn't. Both are private; the toggle trades intelligence for speed, never privacy.
- **Real actions, not suggestions** — after you review and confirm, tasks become actual `EKReminder`s and Calendar holds. Nothing is written without an explicit tap.
- **Machine-readable privacy** — the privacy manifests declare zero data collection and zero tracking, and even crash diagnostics (MetricKit) are written only to local files.

## How it works

```mermaid
flowchart LR
    A["🎙 Voice / text capture"] --> R{Direct<br>command?}
    R -- "「text Priya…」" --> T["Task router<br>@Generable routed actions<br>(regex router offline)"]
    R -- "capture" --> B{Mode}
    B -- "Smart" --> C["Foundation Models<br>@Generable DailyBrief<br>(constrained decoding)"]
    B -- "Instant" --> D["Deterministic<br>rules engine"]
    C -- "typed streaming partials" --> E["Normalizer"]
    D --> E
    C -. "free/busy tool call" .-> K[("EventKit<br>Calendar")]
    T --> F
    E --> F["Editable Action Review"]
    F -- "user confirms" --> G[("Reminders &<br>Calendar")]
```

The engine details that matter:

| Capability | Implementation |
| --- | --- |
| Guided generation | `@Generable`/`@Guide` `DailyBrief` contract with `streamResponse(generating:)` — the framework's constrained decoding guarantees schema conformance, so there is no JSON-repair path anywhere in the app |
| Typed streaming | `PartiallyGenerated` snapshots map to typed partials; the headline renders within the first tokens while tasks are still generating |
| Session lifecycle | One `LanguageModelSession` per conversation — a new capture starts clean so nothing leaks from the last one, refine turns share the session, and prewarm (at launch and on the first keystroke) loads both the brief session and a ready routing session before Generate is tapped |
| Context management | Rolling-window transcript compression (`ConversationMemory`); on projected or actual overflow the session is rebuilt with a condensed digest and retried |
| Tool calling | Three Foundation Models `Tool`s: `CalendarAvailabilityTool` reads real free/busy so scheduling lands in open slots, `RemindersLookupTool` lists open reminders so the model never proposes a duplicate task, and `ContactsLookupTool` resolves first names to real people |
| Error taxonomy | Every `GenerationError` and `UnavailableReason` maps to a typed `GenerationFailure` (including a `timedOut` case from bounded stage deadlines); the deterministic fallback keeps every capture producing a brief, with the reason and a stable machine-readable category preserved in diagnostics |
| Bounded deadlines | Model streaming, command routing, tool reads, contact enrichment, and history persistence all run under cooperative deadlines — a wedged system service degrades into the typed-failure fallback path instead of hanging the run |
| Due dates | The model resolves relative deadlines to ISO-8601 dates; a deterministic parser handles the rules path and confirmed writes |
| Direct-command routing | Commands skip the brief: a few-shot `@Generable` router (greedy sampling — same command, same route) classifies message/email/event/reminder, extracts recipient + date + time, and drafts the message at parse time. Deferred shapes route too ("Hi amma how are you? Send this now" — the greeting names the recipient), and a multi-line dump partitions: command lines become one card each, the rest goes through the brief extractor, nothing vanishes. A regex router is the floor on every device |
| Model output reconciliation | Every routed action passes seven deterministic policies earned from live failures — admissible type, source grounding, clause-echo rejection, deduplication, location grounding, priority floor, temporal correction — each with a stable rule ID; what fired and whether each proposal was accepted, modified, or rejected is recorded in diagnostics without recording content. Generated dates carry pattern guides in the decoding contract and are validated against real calendar semantics (Feb 30 dies deterministically) |
| Proper-noun recovery | A contact-aware post-final resolver corrects ASR name misses ("mirror" → "Mira") using phonetic-skeleton + edit-distance evidence against known contacts only, reporting ambiguity instead of guessing — measured in the speech eval's ablation ladder |

## System integration

- **Siri & Shortcuts** — *"Capture a thought with LocalAssist"* opens straight into a live recording; summaries are exposed as App Entities so Shortcuts can chain them into other apps.
- **Spotlight** — briefs are donated as `IndexedEntity` content, searchable from system search today and pre-adopted for Siri personal-context integration.
- **Capture from anywhere** — a share extension (select text in any app → Share → LocalAssist), the system **Scan Text** camera (the AutoFill Live Text flow, straight into the capture box), voice, or paste.
- **One input, no filing** — there are no capture-type pickers. Typed and scanned text is classified on device (meeting notes vs. errands vs. free-form), voice tags itself, and the Smart prompt asks the model to infer the capture type before summarizing.
- **Widgets** — one-tap capture from the Lock Screen, plus a **Due Today** widget that reads shared app-group history and raises its Smart Stack relevance while tasks are open.
- **Task loop** — check tasks off in the Today view; done-state persists, feeds the widget, and shows up in the morning brief ("3 due today · 1 already done").
- **Interactive snippet confirmation** — reminder creation from Siri/Spotlight shows a preview card and writes only after confirmation; confirmed message drafts open a real pre-filled composer.
- **Morning brief** — an opt-in, fully local notification each morning, with read-aloud available in-app via on-device voices.
- **Diagnostics on the phone** — Settings shows the current model session's transcript read-only (instructions, prompts, tool calls, responses), so tool behavior is inspectable without a debugger. Stays on device.

## Getting started

```bash
# Full Xcode toolchain required: plain CommandLineTools builds but silently skips XCTest.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift test                              # 231 tests
swift run localassist-selftest          # 47 end-to-end checks
swift run localassist-eval --min-score 0.9
swift run localassist --text "Call Mom tonight, pick up the birthday cake Saturday, and book the dentist for next week." --plain
swift run localassist-bench --iterations 100 --warmup 5 --concurrency 4
swift run localassist-speecheval --output docs/evals   # TTS→ASR→tasks round trip

# iOS app
xcodegen generate
open LocalAssist.xcodeproj              # scheme: LocalAssist → iPhone simulator → ⌘R
```

**On your iPhone:** a free Apple Account / Personal Team is enough to install from Xcode. For the Smart path, use an Apple Intelligence-capable iPhone on iOS 26 with Apple Intelligence enabled; voice capture asks for microphone and speech permissions on first use. The simulator covers UI, typed input, and the Instant path.

## Quality & performance

Verification is deterministic and CI-gated — no LLM judges, no flaky assertions:

| Check | What it covers | Status |
| --- | --- | --- |
| `swift test` (231) | Fallback policy (proof every typed `GenerationFailure` falls back with zero further model calls), error taxonomy, typed streaming order, map-reduce chunking, task completion persistence, cancellation (incl. deadline gate side-effect proofs), concurrency, due-date parsing, local-day due-date policy, capture-kind inference, direct-command detection and routing, routed-action reconciliation with rule-ID findings, generated date/time calendar validation, sms handoff encoding, tool calls, executor receipts, conversation memory + 30-turn stress, legacy history decode, WER alignment, ProperNounResolver, voice session timeline, deletion + Spotlight tombstone outbox, redacted diagnostics export, cohort assignment + warmup-outcome gating + cold-campaign envelope, eval scorers | ✅ |
| `localassist-selftest` (47) | End-to-end scenario checks runnable on any machine | ✅ |
| `localassist-eval` | Task recall, due-date accuracy, action mapping, structure compliance, hallucination probes over a fixed dataset; dated reports in [docs/evals](docs/evals); CI gates the deterministic path below 0.9, and the live on-device model's committed baseline is 0.89 | ✅ 1.00 (deterministic) |
| `localassist-bench` | p50–p99 latency, throughput, peak memory, fallback rate, cancellation timing; baselines in [docs/performance](docs/performance) | ✅ |
| `localassist-speecheval` | End-to-end speech: every eval case is spoken by the system synthesizer, transcribed through the app's SpeechAnalyzer stack, scored for word error rate, and run through the task pipeline next to a text baseline — recognition errors surface as the task-accuracy cost they cause | ✅ 0.07 WER |
| XCUITest smoke | Real-UI flow on a simulator: offline auto-run produces an action review, all four tabs navigate | ✅ |
| SwiftLint | Style and correctness lints on every push | ✅ |

Profiling with Xcode Instruments (Time Profiler + Allocations + Points of Interest, `OSSignposter` subsystem `com.saithej.localassist`) drove a refactor that moved generation orchestration, action preparation, and history persistence off the SwiftUI Main Actor. The measured result — full breakdown in the [Instruments summary](docs/profiling/instruments-summary.md), signpost catalog in [docs/instrumentation.md](docs/instrumentation.md):

| Scenario | Before | After |
| --- | ---: | ---: |
| p50 latency | 860 ms | 610 ms |
| **p95 latency** | **1,420 ms** | **910 ms** |
| Peak memory | 184 MB | **171 MB** (under the 185 MB envelope) |
| Cancellation response | 220 ms | 65 ms |

Both configurations exercise the Smart-brief Foundation Models path end to end; latency is the wall-clock duration of the `Summarize` signpost (Generate tap → completed brief in the review UI), and peak memory is the app-process peak reported by Allocations + VM Tracker. The [Instruments summary](docs/profiling/instruments-summary.md) states the session's provenance in a table — device class, build configuration, N, cohort, saved artifacts — including what the session notes did **not** record, so anyone quoting the numbers quotes the conditions with them. The pinned re-run recipe for a fresh device baseline lives in [docs/performance/live-protocol.md](docs/performance/live-protocol.md); a debug-only measurement harness (Settings → Measurement) runs 160 warm samples of `EvalDataset.standard` alongside a cold-launch campaign envelope (device, OS, build, commit SHA, expected source) so future numbers stay tied to the conditions they were taken under.

## Package layout

| Module | Responsibility |
| --- | --- |
| `LocalAssistCore` | Platform-agnostic engine: validation, typed partials, failure taxonomy, normalization, deterministic fallback, due-date parsing, conversation memory, action seams, history, metrics |
| `LocalAssistFoundationModels` | On-device adapter: `DailyBrief` contract and the `FoundationModelsSummarizer` actor |
| `LocalAssistSystemTools` | EventKit calendar free/busy, open-reminders, and Contacts lookup tools + `SystemActionExecutor` for confirmed writes |
| `LocalAssistAppIntents` | App Entities, App Shortcuts, capture intent, snippet-confirmed reminder intent |
| `LocalAssistAppUI` | Liquid Glass tabbed surface (Home · Today · History · Settings), single self-classifying input, voice transcription, Action Review, morning brief |
| `LocalAssistEvalKit` + `localassist-eval` | Eval dataset, scorers, reports, CI gate |
| `LocalAssistCLI` / `LocalAssistBenchmarks` / `localassist-selftest` / `localassist-speecheval` | Demo CLI, performance harness, machine-independent end-to-end checks, and the TTS→ASR→tasks speech accuracy harness |

A point-by-point implementation map lives in [docs/apple-readiness.md](docs/apple-readiness.md).
