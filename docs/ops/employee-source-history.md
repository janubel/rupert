# Employee source history

Release status: **implementation undergoing deployment verification**. This guide describes the implemented scope; it is not a claim that the new source-history views have passed live deployment checks.

## Find every available source record

Open **Timesheets** and use **View all Rupert timesheets**, **View Square history** or **View C-Trax history**. Rupert's default **Needs review** queue contains submitted Rupert timesheets; it does not limit the separate source-history links. Square and C-Trax history open without a date, employee or source-status filter and paginate the retained records. Clear any filters to return to that view.

The history covers the records returned by a complete read of the configured source account, together with previously retained records. It does not claim records that the source account cannot access or that the native endpoint no longer returns. Source reads are bounded and must finish validation before local publication; a failed or incomplete read preserves prior history. Native pagination is not a remote point-in-time transaction, so source changes during a read may require a subsequent refresh.

Active reviewers with `timesheets.read` plus `timesheets.review` or `timesheets.write` can inspect all employees in their workspace. Administrators, managers and shift leaders qualify through their default permissions. An active account administrator with `timesheets.read` can also inspect source history without approval permission. Effective permission overrides still apply. Employee filters include inactive historical profiles and **Employee not matched**; status and date filters narrow the view explicitly. Source date filters use the original clock-in date.

Ordinary employees see only history linked to their own uniquely identified active or on-leave worker profile. Changing an employee ID in a URL or export request does not expand that access. Inactive employees' historical records remain available to authorized reviewers without reactivating employment or issuing accounts. All views and exports remain workspace scoped and use `no-store` responses.

## Read punches and held records

Square history includes open, unmatched, invalid, conflicting, changed and missing records as well as imported history. Detail pages show the latest source clock-in, clock-out, timezone, source status and break punches, including the paid/unpaid flag when supplied. Punch CSV downloads preserve those distinctions. Original counted hours, unpaid break time and source-local daily allocation remain separate from the latest source punches. An open or unmatched record can therefore show punches without contributing counted hours. See [Square timecard history](square-timecard-history.md) for counting and refresh rules.

C-Trax history preserves both source-reported hours and elapsed clock time. These may differ because of source adjustments or breaks whose treatment has not been verified. The labor endpoint does not establish break punches or payable time; Rupert does not invent missing breaks or subtract a guessed break allowance. Open, unmatched, invalid, overlapping, deleted, changed and missing observations remain reviewable.

A C-Trax record with a native employee identity but no store assignment is **Unassigned**. A missing store is not a missing employee and is not silently mapped to a store. The record retains the native identity and available clock/hour evidence for review. A nonempty store ID outside the authenticated account's permitted stores rejects publication instead of accepting an unverified store scope.

## Original, latest and retained observations

C-Trax keeps the first source observation and its normalized punches/hours unchanged. Detail pages and history CSV distinguish that original evidence from the latest source punches and reported hours. A shift first read while open can later display its closed punches without replacing the original open observation.

Each distinct C-Trax source/status transition appends an encrypted, immutable observation in the same publication transaction. Successive corrections, reversals, disappearance and reappearance remain in sequence; an identical refresh adds no duplicate observation. This records changes Rupert actually observes, not edits made and reverted between reads. The detail page shows the latest observations and offers **Download all observations CSV** for the full retained sequence. A missing observation retains the last returned source evidence and identifies the absence; absence is not a zero-hour replacement or deletion.

Original/latest source payloads and C-Trax observation payloads are encrypted at rest. Pages and CSV expose selected clock, hour, identity and review fields rather than raw nested source data. CSV text cells neutralize spreadsheet formulas. Export access follows the same employee/reviewer and workspace boundary as the page.

## Identity and use of hours

Native source identities resolve through retained employee source identities. Names, shared email addresses and similar-looking profiles do not establish a match. An authorized administrator can consolidate confirmed duplicate profiles; source identities and Square/C-Trax history follow the canonical employee while original employee rows and consolidation evidence remain retained. History-linked employees cannot be deleted through the normal workflow.

Square's previously counted historical days continue to appear once in personal reports and calendars under the existing Square rules. C-Trax source hours remain excluded from personal hour totals and Rupert payroll. Neither source import creates Rupert approvals, pay rates, overtime classifications, payslips or payment status. New Rupert payroll uses its existing approved-entry workflow.

Rupert, Square and C-Trax can describe the same work. Their counts and hours remain separate; do not add overlapping records across sources or treat source verification as Rupert approval or proof of payment. Review conflicts and corrections before relying on the evidence.

## Deployment and recovery

`CreateCtraxLaborShifts` adds the source-shift and observation tables. A consistent private database/configuration checkpoint, restored-copy migration and render rehearsal, regression checks and live access/read verification are required before recording the deployment as verified. Preserve the complete migration set, encryption keys, retained history, identity links and existing authentication fixes. A rollback must preserve newer business records and both new history tables; never restore an older database over current employee hours or access changes. Keep real employee records, native exports, credentials and recovery locations outside this public repository.
