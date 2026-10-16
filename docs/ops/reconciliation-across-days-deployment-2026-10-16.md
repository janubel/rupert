# Reconciliation across-day UX deployment — October 16, 2026

[PR #62](https://github.com/techmore/rupert/pull/62) deployed application revision `b42f730b043bd2cdbac343d0ab3e4f2abe7bd393` to SER8. The complete prior `cf7202c30e018fc7b8179859062613e9c98043f6` release is preserved, including NMI sandbox checkout, stock matching and employee consolidation. The employee chat supplied the focused Expo 58.0.12 dependency alignment. This pass adds no migrations; subsequent receipt changes are documentation only.

## Workflow

**Money → Reconciliation across days** at `/reconciliation_follow_ups/overview` shows seven Eastern business dates ending yesterday by default. A compact date strip shows missing-control, comparison-issue and open-follow-up counts, with direct links to each day. Week navigation, an ending-date picker and Include today support earlier dates and the current day. Existing exact-scope open report requests are linked from missing-control prompts.

The queue adds all-date shortcuts for overdue, due today, unassigned and report requests without linked originals. Purpose/evidence filters combine with source, owner, status and covered date. Cards show due urgency, ownership, latest progress and linked-evidence state. Daily reconciliation, the library and the pending Drive screen link into this local workflow.

Observed control gaps are separate from manually expected reports. A monthly request appears on each covered date but remains one request. Missing linked evidence does not mean a file is absent from the library. No amounts or overlapping reports are summed, requests are not created automatically and no overview state certifies a completed day.

## Verification

- Exact combined [Rails CI](https://github.com/techmore/rupert/actions/runs/38887667318): PostgreSQL 1,317 tests / 9,684 assertions, zero failures/errors and two adapter-specific skips; SQLite 1,317 tests / 9,699 assertions, zero failures/errors/skips. RuboCop inspected 689 clean files. Product-site and documentation checks passed. The [employee-mobile check](https://github.com/techmore/rupert/actions/runs/38887667393) passed after its focused Expo compatibility fix.
- A consistent private production-copy rehearsal preserved every table count and verified daily/library/overview rendering, archive replay, original decryption and rollback of synthetic follow-up/history operations. Seven-date rendering took approximately 0.03 seconds on that copy.
- Synthetic desktop/390px phone checks covered compact date navigation, prefilled requests, reuse of existing requests, due-today filtering and progress/evidence cards. Live read-only checks verified the same navigation and correct pending Drive state without creating production test requests.
- Promotion selected one verified release asset manifest and preserved earlier manifests privately. Public health returned HTTP 200; web/jobs were active on clean release source.
- All 42 eligible retained local originals/report versions passed checksums. A consistent encrypted off-host checkpoint passed saved-key restoration of originals, follow-up history, library/report/overview queries, archive-member decryption and all member checksums, then was pushed to the owner-verified private backup destination.

**Google Drive remains pending.** No consent attempt, credential change, cloud folder or verified upload was introduced. Existing originals remain encrypted and available in Rupert. See the [daily workflow guide](daily-reconciliation-retention.md), [prior follow-up receipt](reconciliation-follow-ups-deployment-2026-10-16.md) and [Drive checkpoint](drive-retention-deployment-2026-10-16.md). Private originals, financial amounts, employee links and runtime keys remain outside public Git.
