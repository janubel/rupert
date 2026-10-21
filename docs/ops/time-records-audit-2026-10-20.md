# Time records audit and Time workspace pass — October 20, 2026

A read-only inspection of the production SQLite database on SER8 (Incus container `rupert`, revision `bbf367de`) taken at 23:30 America/New_York on October 20, 2026, followed by a navigation and reporting pass over the time pages. No production row was created, changed or deleted; no upstream Square or C-Trax write was made. Counts below are workspace totals; employee names, native IDs and payloads stay out of this public repository.

## What Rupert holds

| Source | Records | Earliest clock-in | Latest clock-in | Counted hours | Held out of totals |
| --- | --- | --- | --- | --- | --- |
| Square timecards | **918** | 2025-09-27 | 2026-10-20 | **5,260.2** (912 imported) | 2 open (no end yet) · 4 conflicts (29.7h) |
| Square timecard days | 909 | — | — | — | per-day split of the counted cards |
| C-Trax labor shifts | **24** (26 observations) | 2024-09-21 | 2026-10-15 | 0 (never payable) | 13 imported · 7 conflict · 2 unassigned · 2 unmatched |
| Rupert clock shifts | 2 | 2026-10-16 | 2026-10-17 | 9.1 | 0 |
| Rupert timesheets | 15 (13 demo, 2 live drafts) | 2026-07-13 | 2026-10-18 | 550h over 70 entries | demo sheets are excluded from payroll |

Square is the real punch record for this business: roughly 60–105 timecards a month since October 2025 (~300–545 hours/month), 11 matched team members across 4 Square locations (one location carries 896 of the 918 cards; the other three carry 20 between them and look like a second store and short-lived device locations). Automatic refresh is live — the newest card was seen at 23:30 on the audit date and both Square and C-Trax `last_seen_at` stamps are current.

C-Trax labor is sparse (24 shifts over two years) and the automatic 15-minute refresh is retaining it correctly, but it is **not** a usable hours record and should stay comparison-only.

## Outstanding records to resolve

1. **One C-Trax shift reports ~3,190 hours** (started February 2025, status `imported`). This is a missed clock-out at the register, not real time. It inflates every C-Trax total and the "All sources" unified list. The new punch report flags any punch over 16 hours in red (list, calendar and CSV) so it is visible without reading raw payloads. No fix is needed in Rupert's data: C-Trax hours never count; correct it at the source if C-Trax labor matters.
2. **Four Square conflicts, all for one staff member, October 16–20, 2026.** These overlap Rupert clock shifts made during the time-clock pilot on October 16–17 and each other. They hold 29.7 hours out of totals. Decide which record is authoritative for those four days (the Square card or the Rupert punch) and either delete the pilot Rupert punches or accept the Square hours; do not add both.
3. **Two open Square timecards** (two staff members still punched in at the time of the read). Normal; they count once they close.
4. **Two C-Trax shifts with no matched employee and two unassigned** (no store). They need a confirmed identity in **Staff → consolidate** or can stay as history.
5. **Duplicate employee shells.** The workspace has 31 employee rows for about 14 people: the Square timecards resolve to the consolidated C-Trax-sourced profiles, leaving 13 Square-sourced and 4 SwipeSimple-sourced rows with zero time records and the same first names as active profiles. They clutter every staff dropdown. Consolidate them into the profiles that hold the history (`merged_into_id` is already supported) rather than deleting them, so source identities keep resolving.
6. **Historical reach.** The Square reader paginates the whole `labor/timecards/search` feed with no date floor, so 2025-09-27 is the oldest timecard Square returns for this account, not a Rupert limit. Older staff time (before Square timecards were used) lives in C-Trax only where it was punched there, which the 24-shift count says was rarely. Nothing further can be backfilled from these two sources; see [historical records](historical-records.md) for the sales/payment sources.

## What changed in the app (this branch)

- **One Time workspace header** on Timesheets, Punch report, Square history, C-Trax history, Team schedule and Payroll (`shared/_time_navigation`, `TimeWorkspaceHelper`), with the current page marked. The six "Where to go next" cards and the five source cards on the Timesheets page are gone; the links they carried are in the header or the coverage strip.
- **Timesheets leads with the review queue** (tabs, counts, table) instead of the week calendar. The calendar is a collapsible section below the table that opens itself when someone is clocked in or a week is chosen. Weeks-at-a-glance and upcoming time off sit side by side under it.
- **Punch report** (`/people/punch_history`, formerly "Punch history") now includes C-Trax shifts, offers one-tap ranges (this/last Thu–Wed pay week, this/last month, year to date, all history), shows a staff × source hours matrix with counted totals and flag counts, highlights punches over 16 hours as probable missed clock-outs, and adds a `Flag` column to the CSV. C-Trax rows are never counted.
- **Time sources strip** (`TimeSourceCoverage`, `shared/_time_source_coverage`) on Timesheets and the Punch report: records, counted hours, held records, date reach and last successful read per source.

## Verification

- `test/integration/punch_history_test.rb` gains a C-Trax/flag/preset case; `timesheet_reviews_test.rb` now asserts the queue precedes the calendar. The people/timesheet/source/consolidation integration set passed locally on SQLite (131 runs before the new case).
- Production was read with `sqlite3 -readonly`; no application process, service or schedule was touched. Deploying this branch follows the normal [release process](release-process.md); it adds no migration, dependency or schedule.
