# LocalAssist Speech Eval Report

- Configuration: speech + deterministic-fallback
- Completed: 2026-07-11T03:23:54Z
- Mean word error rate: 0.09
- Mean task composite — speech input: 0.91
- Mean task composite — text input: 1.00
- Synthetic audio caveat: TTS is cleaner than a human speaker; treat WER as an upper bound and a regression tripwire.

Ablations per case: gold text (ceiling) → full accumulator (app path) → proper-name-corrected → finals-only (lost volatile tail).

| Case | WER | Corr WER | Final WER | Sub | Del | Ins | ASR (ms) | Speech | Corrected | Final-only | Gold |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| blockers-message | 0.12 | 0.06 | 0.12 | 2 | 0 | 0 | 515.32 | 0.88 | 1.00 | 0.88 | 1.00 |
| urgent-deadline | 0.09 | 0.09 | 0.00 | 1 | 0 | 0 | 190.31 | 1.00 | 1.00 | 1.00 | 1.00 |
| checklist-update | 0.00 | 0.00 | 0.00 | 0 | 0 | 0 | 188.71 | 1.00 | 1.00 | 1.00 | 1.00 |
| meeting-notes | 0.31 | 0.31 | 0.24 | 9 | 0 | 0 | 257.01 | 0.82 | 0.82 | 1.00 | 1.00 |
| single-task | 0.00 | 0.00 | 0.00 | 0 | 0 | 0 | 115.37 | 1.00 | 1.00 | 1.00 | 1.00 |
| bullet-list | 0.12 | 0.12 | 0.12 | 2 | 0 | 0 | 177.65 | 0.77 | 0.77 | 0.77 | 1.00 |
| no-deadline | 0.00 | 0.00 | 0.00 | 0 | 0 | 0 | 159.40 | 1.00 | 1.00 | 1.00 | 1.00 |
| mixed-noise | 0.08 | 0.08 | 0.08 | 1 | 0 | 1 | 215.51 | 0.82 | 0.82 | 0.82 | 1.00 |

## Transcripts
- blockers-message: Review the onboarding dock, send mirror the blockers by Friday, and schedule a design sync next week.
- urgent-deadline: Finish the quarterly reportort ASAP, email finance the draft numbers tomorrow.
- checklist-update: Update the launch checklist before the beta ships. Add the new QA steps and check the crash dashboards.
- meeting-notes: Stand-up notes. Infromigration is blocked on the off token rollout. Priya will share the run book, bookook a warroom for Thursday and follow up with the platform team.
- single-task: Call the vendor about the renewed contract terms today.
- bullet-list: Draft release notes for 2.4 cent of beta invite email on Monday Review, open crash reports.
- no-deadline: Prepare interview questions for the platform engineer role and share them with the panel.
- mixed-noise: Lunch was great. Weather is nice. Ship the hot fix build tonight and confirm the rollout with Dana. Maybe we should think about the offsite sometime.
