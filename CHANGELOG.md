# Changelog

All notable changes to LocalAssist are documented here.

## Unreleased

### Product
- The brief streams in its own final layout: the headline lands at full
  title size, task rows render with their real priority dot and pills
  (placeholder-redacted until each field arrives), and completion is the
  same card finishing in place instead of a caption-sized skeleton
  swapping into a different one. The phase line sits where the finished
  card's engine-and-latency line goes, and streaming rows keep stable
  slot identity so mid-stream revisions update text without tearing rows
  down.

### Engine
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
