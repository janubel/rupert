# Finance and reconciliation audit — October 16, 2026

Read-only audit of the live SER8 instance (`rupertpos.com`, Incus container `rupert`, revision `9b6ba9b`) against its SQLite database, plus a code review of the Financial report, Daily checks, Financial close and Money reconciliation. Nothing on the server was written, restarted or deployed. No credentials or customer data were copied off the server; only aggregate counts were read.

## Findings

| # | Finding | Evidence (live, read-only) | Status |
| --- | --- | --- | --- |
| 1 | Refunds are understated. Orders marked `refunded` have no refund row, so the Financial report shows $0 refunds while the sale silently drops out of revenue. | 3 refunded orders (one is $63.60), `refunds` table empty. | Warning on the Financial report and a **Books check** item. Recording the refund amount still needs the source receipt. |
| 2 | Sales-by-location omitted every order without a location (inner join). | 509 of 11,594 orders (all Shopify web orders) have no `location_id`. | Fixed: shown as "Unassigned". Listed in Books check. |
| 3 | Square has had no new orders since 2026-09-28. The Square access token is absent in setup, so this is a stalled source, not a quiet one. | Latest Square order 2026-09-28; the 2026-10-16 live-sync audit records the token as missing. | Books check now flags any source with no order for 3+ days. Connecting Square is the owner's call. |
| 4 | Paid orders with a total but no payment cannot appear in tender totals. | 0 for Shopify. 149 Square orders have no payment, all $0.00 to $24.11 in total, last 2026-08-12 (comps or zero-tender). | Books check item (fix when non-zero within the window). |
| 5 | No register controls have ever been retained, so every daily comparison reads "missing". | `reconciliation_documents`: 0 `register_control`; 21 daily and 14 period archives exist. | Books check lists recent sales days with no control and links straight to the upload for that day. |
| 6 | Scheduled import failures: 225 total, latest 2026-10-15 20:15 (Net::ReadTimeout), earlier Square HTTP 504 and a token-exchange 502. Current runs succeed every 15 minutes. | `SyncRun` | Books check fails if the most recent import failed. |
| 7 | systemd inside the container logs `Failed to kill control group ... Permission denied` for `rupert-web` and `rupert-jobs` at restart (18:52). Services recover, but restarts leave left-over processes. | `journalctl` in container | Not changed. Needs an Incus cgroup delegation decision before the next restart-heavy deploy. |
| 8 | Order totals reconcile with payments where payments exist: payments equal totals on every paid order that has one (0 over- or under-paid), no negative amounts, no tax above total, no orphan payments. | SQL cross-checks | Pass. Now re-checked on every Books check. |

Pre-existing, not changed: `FinanceFlowTest#test_vendor_payments_index_lists_recent_payments` fails on a clean checkout of this branch when run in a UTC container (date-dependent fixture).

## What was added

**Books check** (`/books_check`, Money navigation and the Reports header): one page that answers "are the books clean?" with a verdict (All clear / Worth a look / Needs fixing), each check showing the exact count and dollars, the sample rows, and a link to where to act. CSV export. Read-only; `reports.read` required; `Cache-Control: private, no-store`.

Checks: source freshness, import health, paid orders without payment, payment vs order total, refund records, location assignment, impossible amounts, register controls for recent days, day reviews, overdue follow-ups, and a SHA-256 re-verification of recently retained originals.

Rules kept: no writes, no cross-layer summing, unknown stays unknown, CSV cells are formula-escaped.

## Not done, needs the owner

- Deploy to rupertpos.com: follows the PR, CI and production-copy rehearsal process in `docs/ops`.
- Connect Square (token), record the three missing refund amounts, and decide whether Shopify channels should map to a Location.
