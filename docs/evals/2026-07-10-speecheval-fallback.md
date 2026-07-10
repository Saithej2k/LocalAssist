# LocalAssist Speech Eval Report

- Configuration: speech + deterministic-fallback
- Completed: 2026-07-10T16:17:58Z
- Mean word error rate: 0.07
- Mean task composite — speech input: 0.93
- Mean task composite — text input: 1.00
- Synthetic audio caveat: TTS is cleaner than a human speaker; treat WER as an upper bound and a regression tripwire.

| Case | WER | Sub | Del | Ins | ASR (ms) | Speech score | Text score | Δ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| blockers-message | 0.12 | 2 | 0 | 0 | 611.63 | 0.88 | 1.00 | -0.12 |
| urgent-deadline | 0.00 | 0 | 0 | 0 | 164.29 | 1.00 | 1.00 | 0.00 |
| checklist-update | 0.00 | 0 | 0 | 0 | 177.32 | 1.00 | 1.00 | 0.00 |
| meeting-notes | 0.24 | 6 | 0 | 1 | 268.95 | 1.00 | 1.00 | 0.00 |
| single-task | 0.00 | 0 | 0 | 0 | 125.01 | 1.00 | 1.00 | 0.00 |
| bullet-list | 0.12 | 2 | 0 | 0 | 184.54 | 0.77 | 1.00 | -0.23 |
| no-deadline | 0.00 | 0 | 0 | 0 | 163.32 | 1.00 | 1.00 | 0.00 |
| mixed-noise | 0.08 | 1 | 0 | 1 | 208.55 | 0.82 | 1.00 | -0.18 |

## Transcripts
- blockers-message: Review the onboarding dock, send mirror the blockers by Friday, and schedule a design sync next week.
- urgent-deadline: Finish the quarterly report ASAP, email finance the draft numbers tomorrow.
- checklist-update: Update the launch checklist before the beta ships. Add the new QA steps and check the crash dashboards.
- meeting-notes: Stand-up notes. Infromigration is blocked on the off token rollout. Priya will share the run book. Book a war room for Thursday and follow up with the platform team.
- single-task: Call the vendor about the renewed contract terms today.
- bullet-list: Draft release notes for 2.4 cent of beta invite email on Monday Review, open crash reports.
- no-deadline: Prepare interview questions for the platform engineer role and share them with the panel.
- mixed-noise: Lunch was great. Weather is nice. Ship the hot fix build tonight and confirm the rollout with Dana. Maybe we should think about the offsite sometime.
