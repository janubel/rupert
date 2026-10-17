# Compliance, retention, reconciliation and accounting review — October 17, 2026

Scope: how Rupert supports a person who looks over the books each day or week and accepts them into a dated, attributed record. Live checks were read-only aggregates on the SER8 database and a throwaway copy. This is an operational review, not legal, tax or audit advice or a certification.

## Findings

| # | Finding | Evidence | Status |
| --- | --- | --- | --- |
| 1 | **Reviews could never stay current.** The daily report fingerprint included each source's last import time, so every successful sync (every 15 minutes) changed it. Any review, follow-up or close bound to a fingerprint read "evidence changed" within minutes. | On a copy of production, adding one successful sync changed the fingerprint while the evidence-only fingerprint stayed identical. Zero reviews, zero close packages exist live. | Fixed: the fingerprint now covers evidence only. Import staleness is reported as an issue, not a data change. |
| 2 | **No weekly or one-click human approval.** Only a per-day review existed, bound to the unstable fingerprint, with no source network address and no record of what the approver saw. | `daily_reconciliation_reviews` is empty live. | Added **Approve books** (`/approve_books`): daily and weekly, frozen summary, name, UTC time, network address, tamper-evident hash chain. |
| 3 | **Exports and downloads left no trace.** CSV reports, retained originals, native source files, activity and database backups could be taken without an audit entry. | No logger calls in those actions. | Every export and download now writes a `data_exported` entry. |
| 4 | **Money-out edits were not attributable in detail or period-aware.** Expense updates logged no before/after values, and changing a record inside an approved day was silent. | `expense_updated` entries had no details. | Updates log changed fields; edits inside an approved period warn the editor and log `edit_in_approved_period`. The approval then reads "changed". |
| 5 | **The off-host backup has never succeeded.** Local backups run every six hours on the host; Google Drive instance backup and document retention are disconnected. | `BackupLog` and `retention_drive_items` are empty. | Books check now flags it. Connecting Drive needs the platform administrator. |
| 6 | **Money-out is not being recorded.** No expenses or vendor payments exist, so approvals show $0 out. The books that can be approved are the sales side only. | `expenses`, `vendor_payments` empty. | Owner decision. |
| 7 | **Rupert is an evidence-review system, not a general ledger.** There is no double-entry posting, accrual or period close that locks edits. | Chart of accounts exists; no postings. | By design, stated on the page. Approvals do not lock records; they detect change. |
| 8 | **No register controls and no uploaded originals by a person.** Every retained document was generated automatically, so every daily comparison reads "missing". | 789 documents, none with an uploader; no `register_control`. | Books check lists affected days with a one-click upload link. |
| 9 | Four-eyes is not enforced: one person with report-write access can approve. | Role matrix | Recorded who approved; enforcement left as an owner decision. |

## Retention matrix

| Record | Kept | Can the app change or delete it? | Evidence of who |
| --- | --- | --- | --- |
| Book approvals (new) | Indefinitely | No update or delete; hash-chained | Name, user id, UTC time, address, user agent |
| Retained originals and archives (`reconciliation_documents`) | Indefinitely, encrypted | No update or delete | SHA-256, uploader when manual, activity entry |
| Daily reviews, follow-up history | Indefinitely | Append-only | Reviewer / actor |
| Activity (audit) log | 7 years (was 90 days, changed in PR 99) | Pruned only by the nightly job past 7 years | Actor name, user id |
| Access (sign-in) log | 2 years | Pruned past 2 years | Email, address, outcome |
| Orders, payments, refunds | Until removed by an operator; never pruned by the job | Imports update orders | Source ids |
| Expenses, vendor payments | Soft-delete with restore | Editable; edits logged with changed fields | Actor in activity log |
| Inventory movements | 180 days | Pruned | n/a |
| Ledger mirror | 365 days | Pruned (re-importable) | n/a |
| Database backups | Local, six-hourly; off-host not yet | n/a | Host timer |

## Not done, needs the owner
Connect Google Drive backup; decide whether to track money-out in Rupert; decide on four-eyes approval; enter register controls for recent days; confirm the 7-year audit-log retention suits the business and its jurisdiction.
