# Missing-report and overdue-action UX — October 16, 2026

[PR #62](https://github.com/techmore/rupert/pull/62) deployed application revision `689d784238d52439e1a71b3c260d7a23282826d6` to SER8, preserving the complete prior `b42f730b043bd2cdbac343d0ab3e4f2abe7bd393` release and current database/account state. This pass adds no migrations or authentication changes. Subsequent receipt changes are documentation only.

The across-day overview now puts earliest-due follow-ups above the calendar, highlights overdue cards and shows a separate **Register reports to request** count. Its action list contains observed source/currency/location/date pools with neither a current control nor an exact-scope open report request, oldest date first. The first three are visible; a keyboard-accessible disclosure exposes the remainder. Search existing retained files before requesting a report. Other expected invoices and statements still need explicit requests.

Cards offer direct **Record progress**, **Find retained original** and **Add original** actions, or **Download linked original** when linked. Read-only users retain viewing/downloading actions. The daily attention section flags overdue follow-ups across all dates, and the document library offers overdue, due-today and unlinked-original shortcuts. Uploading/linking does not close work or certify a match. No report-request message is sent by these actions.

Validation:

- Exact deployed-revision PostgreSQL/SQLite, RuboCop, product/documentation and employee-mobile CI passed. PostgreSQL: 1,318 tests / 9,701 assertions, zero failures/errors and two adapter-specific skips. SQLite: 1,318 tests / 9,716 assertions, zero failures/errors/skips. RuboCop: 689 clean files. [Rails run](https://github.com/techmore/rupert/actions/runs/38889539135); [mobile run](https://github.com/techmore/rupert/actions/runs/38889539181).
- A consistent private production-copy rehearsal preserved every table count and verified daily/library/overview rendering, direct card actions, progress anchors, archive replay, original decryption and rollback of synthetic follow-up/history probes. Seven-day rendering took about 0.03 seconds on that copy.
- Synthetic desktop/390px phone checks covered priority ordering, missing-report searches, request-context upload forms and progress anchors. The remaining-report disclosure worked with the keyboard. Live read-only missing-report expansion/search/navigation and phone checks passed; no production test follow-ups were created.
- Public health returned HTTP 200; web/jobs were active on clean release source with one verified asset manifest. Current accounts, grants and owner-applied access settings were preserved.
- All 50 eligible local originals/report versions passed checksums. A consistent saved-key restore verified originals, follow-up history, library/report/overview queries. The encrypted off-host checkpoint passed decryption and all member checksums and was pushed to the owner-verified private backup destination.

**Google Drive remains pending.** No consent, credential, cloud-folder or upload changes were made. Local originals remain encrypted and available. See the [workflow guide](daily-reconciliation-retention.md) and [previous across-day receipt](reconciliation-across-days-deployment-2026-10-16.md). Private financial files, employee links and runtime keys remain outside public Git.
