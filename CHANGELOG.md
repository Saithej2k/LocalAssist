# Changelog

All notable changes to LocalAssist are documented here.

## Unreleased

### Production hardening (2026-07-11)
- Briefs can be deleted: long-press a history card (or clear all) and the
  run leaves local history atomically with a durable Spotlight tombstone;
  a coordinator confirms the index deletion and retries at every launch,
  and pending deletions never surface in Shortcuts/Siri queries even
  across a crash window.
- Settings → Diagnostics gains a redacted JSON export: stage timings,
  counts, failure categories, reconciler rule IDs, device state, and the
  last voice session's timeline — structurally content-free, user-initiated
  only.
- Every generation failure is typed (now including bounded-deadline
  `timedOut`), falls back deterministically, and records a stable
  machine-readable category. Model streaming, command routing, tool reads,
  contact enrichment, and history persistence all run under cooperative
  deadlines.
- The routed-action reconciler's seven policies carry stable rule IDs and
  record each proposal's disposition (accepted/modified/rejected) into
  diagnostics — never content. Generated dates/times are pattern-guided in
  the decoding contract and validated against real calendar semantics.
- Voice capture rides out calls, Siri, media-services resets,
  backgrounding, and memory warnings by draining instead of dying, and
  records a monotonic per-session timeline (tap → audio ready → first
  partial → drain).
- A contact-aware proper-noun resolver corrects ASR name misses
  ("mirror" → "Mira") with phonetic + edit-distance evidence, reporting
  ambiguity instead of guessing; the speech eval gained a per-case
  ablation ladder (gold → accumulator → name-corrected → finals-only)
  that measures its downstream recovery.
- Run metrics grew backward-compatible stage timings (TTFT → review-ready
  → persistence), device/build environment, and context-window
  bookkeeping; streaming UI partials coalesce to a stable cadence.
- Eval due dates now compare as resolved local calendar dates rather than
  substrings; the benchmark measures injected incomplete-stream and
  normalization-failure fallbacks (detection → first partial → completion);
  a debug-only device harness runs the eval dataset 20× per case with
  cold/warm cohorts and app-process footprint. CI builds with
  warnings-as-errors under Swift 6 strict concurrency.

### Product
- A dump of one command per line becomes one card per line: "text
  amma…" / "email HR…" / "meeting with Rahul…" / "remind me…" each
  route individually — model when available, rules engine as the floor
  for every line, so no line can vanish — and cards accumulate into the
  streaming panel as each command lands. Line breaks now survive
  validation; they used to be collapsed into one mushed line before the
  router ever saw them.
- New captures start clean: the model session is shared only with the
  refine turns that follow a capture, so a fresh capture can no longer
  surface a task from the previous one. Typing in the capture box
  retires the old conversation and warms the new session early.
- The capture box grows with its text — line by line to a cap, easing
  instead of jumping — and only scrolls internally past the cap, instead
  of a fixed-height pill with a scroll inside.
- Settings grows a read-only Diagnostics section: the current model
  session's transcript — instructions, prompts, tool calls, tool
  outputs, responses, in order, each truncated for display — so tool
  behavior is inspectable on the phone without a debugger. Everything
  stays on device.
- The brief streams in its own final layout: the headline lands at full
  title size, task rows render with their real priority dot and pills
  (placeholder-redacted until each field arrives), and completion is the
  same card finishing in place instead of a caption-sized skeleton
  swapping into a different one. The phase line sits where the finished
  card's engine-and-latency line goes, and streaming rows keep stable
  slot identity so mid-stream revisions update text without tearing rows
  down.

### Engine
- The speech experience is now measured end to end:
  `localassist-speecheval` speaks every eval case with the system
  synthesizer, transcribes it back through the same SpeechAnalyzer
  stack the mic uses, scores word error rate against the spoken
  reference, and runs the transcript through the task pipeline next to
  a text-input baseline — so recognition errors surface as the
  downstream task-accuracy cost they actually cause. First baseline:
  mean WER 0.07, speech task composite 0.93 against a 1.00 text
  ceiling, with name recognition ("Mira" heard as "mirror") the
  dominant cost. Reports are dated into docs/evals with the
  synthetic-audio caveat printed on each one.
- Routed commands answer faster: the routing session is prewarmed at
  launch and on typing instead of built cold at tap time, so a command
  no longer pays instructions processing while the user watches for the
  card. Each command consumes the warmed session (single-turn — its
  transcript must not carry into the next command), a replacement warms
  immediately, and a session warmed before midnight is rebuilt when the
  date it was told changes.
- "Hi amma how are you? Send this now" routes as a message: a deferred
  command no longer needs "to X" when the clause closes the input, and
  the greeting names the recipient the clause left out. Mid-note "send
  this over…" prose still never routes.
- Mail only when the note says mail: an unresolved recipient on an
  `auto` channel now opens Messages, not the mail composer. A phone
  number still means Messages and an email-only contact still means
  mail; only the nobody-matched default flipped.
- The model can now see the user's open reminders before proposing
  tasks: a read-only `RemindersLookupTool` lists incomplete reminders
  (optionally filtered by keyword, dated ones first) so a note that
  mentions the dentist defers to an existing "Book the dentist" instead
  of duplicating it. Same seam pattern as the calendar and contacts
  tools — EventKit-backed live, static provider for tests and previews,
  access requested on first call, denial surfaces as a typed tool error.
- Deferred commands route too: "Hi amma how are you doing, text this to
  amma now" puts the message first and the verb last — the router now
  recognizes "text/send/email this to X" anywhere in a short input and
  makes the action's body the user's own words with the routing clause
  removed, on both the Smart and Instant paths. A leading verb still
  wins ("remind me to text this to amma" stays a reminder).
- The routed-action reconciler collapses duplicate actions, floors
  priority with the family/work keywords the rules engine uses, and only
  honors date cues the command itself contains — a draft that invents
  "today" for a Thursday meeting no longer moves the hold.
- Direct-command routing: short inputs that start with a routing verb
  ("text Priya that Sunday brunch works, 11am", "email HR about leave",
  "remind me to call mom tomorrow", "meeting with Rahul Thursday 3pm")
  skip the brief and become addressed, drafted action cards. The Smart
  path uses a few-shot `@Generable` router contract — validated on-device:
  example-based guides classify correctly where conditional rules fail —
  that extracts type, recipient, date, time, and the message draft in one
  constrained decode, and can split one command into multiple actions.
  A regex router covers Instant mode and non-Apple-Intelligence devices
  with a single conservative action. Compound scheduling captures
  ("schedule the sync and share the agenda") stay on the brief path,
  which extracts every clause.
- Model-drafted command messages are final at review time: confirmation
  opens the composer with exactly the reviewed text plus the LocalAssist
  signature, instead of composing a second draft.
- Explicit clock times now survive into system writes everywhere:
  `DueDateParser` reads "3pm" / "11:30" out of any date hint, so a
  routed "meeting Thursday 3pm" lands at 15:00 instead of the default
  morning slot, and edited dates like "2026-07-12 11:00" round-trip.
- Review-card date edits now win over stale machine dates: changing the
  date on a calendar hold or reminder clears the original ISO payload
  keys that previously outranked the edited text in the executor.

## v1.0.0 — 2026-07-06

The first complete release: a privacy-first, fully on-device capture-to-plan
assistant for iOS 26.

### Product
- Liquid Glass capture surface: one self-classifying text box, mic, system
  Scan Text camera, and a Generate action on a glass control shelf.
- Native tab navigation: Home, Today (with live due-count badge), History,
  and Settings; widget deep links land on the right tab.
- Voice capture with on-device speech recognition; dictation appends to
  typed text instead of replacing it.
- Editable Action Review: reminders and calendar holds are written only
  after explicit confirmation; message drafts open a real composer.
- Due Today Lock Screen/Home Screen widgets, Siri App Shortcuts, Spotlight
  donation, share-extension capture, and an opt-in local morning brief.
- History export as dated Markdown and JSON files.
- App icon: a sleepy owl hugging a phone — your thoughts never leave home.

### Engine
- Foundation Models guided generation with typed streaming partials and a
  session lifecycle tuned live against the real model: a demarcated format
  example replaces the schema in every prompt (A/B-tested), static rules sit
  in higher-privilege instructions, and a deterministic parser overrides the
  model's calendar arithmetic when a task title names a relative day.
- Calendar free/busy and Contacts lookup tools the model calls autonomously.
- Deterministic rules engine covers every device and failure mode, with a
  typed failure taxonomy preserved in diagnostics.
- Local-day due-date policy: bare ISO dates parse in the user's time zone
  everywhere (normalizer, widgets, morning brief, history roundtrip).

### Quality
- 43 unit tests (debug, release, and Address Sanitizer clean), 47
  self-test checks, a CI-gated deterministic eval suite at 1.00, dated
  benchmark baselines, and OSSignposter instrumentation on every stage.
- Zero-warning strict-concurrency build.
