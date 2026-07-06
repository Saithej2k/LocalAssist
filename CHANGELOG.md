# Changelog

All notable changes to LocalAssist are documented here.

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
