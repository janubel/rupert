# Money workspace audit (bookkeeping UI/UX)

Scope: every page in the Finance navigation. "Risk" asks: could this cause a wrong number or a wrong action?
Flow asks the Don't-Make-Me-Think question: does the page say where you are, whether anything is wrong, and the one obvious next step?
Status: **Done** (this branch), **Partial**, **Open** (not changed; see owner questions).

## Pages changed on this branch

| Page | Problem found | Risk | Fix | Status |
|---|---|---|---|---|
| General ledger, Financial reports, Bank reconciliation | Not in the Money navigation at all; only reachable from links on other pages | Wrong action: users keep books in the wrong place | Added a "Books" group to the nav | Done |
| "Ledger" (imported orders) | Named like the double-entry ledger but shows imported sales | Wrong number read as books | Renamed "Imported orders", links to General ledger | Done |
| General ledger list | Only the newest 100 entries could ever be browsed while totals counted all | Wrong number (hidden entries) | Full pagination; memo, account, amount and date filters; void count; balanced status | Done |
| General ledger list | Totals include void entries | Wrong number if read as posted totals | Labelled "includes void entries"; calculation not changed (owner question) | Partial |
| New journal entry | Bad amounts ("1,000") silently became $0 and the row was dropped; a row with no account was skipped; typed values lost on error | Wrong number | Server rejects each problem by line number, keeps input; live totals, balance state, reasons the button is disabled, confirm with amount and date | Done |
| Journal entry detail | "by user #3"; no read-only reason; no way to correct | Wrong action | Shows author, history, lock, void/reversed state, links to account and source; Reverse (date + reason, once) for hand-keyed entries | Done |
| Account page (new) | No way to go from a report figure to its entries | Findability | Account ledger with running balance and totals; linked from chart, trial balance, income statement, entry lines | Done |
| Trial balance / Income statement / Balance sheet | No currency/range label on exports, balance status only red/green text, no drill-down | Wrong number unnoticed | Shared header (dates, currency, explanation), "Balanced / Out of balance by $X" live region, totals rows, print, CSV with status and formula-safe names | Done |
| Expenses | No search/amount filter, removed rows hidden, no author, Edit/Delete available inside locked periods (server refused with a 422 page) | Wrong action | Filters, removed rows visible and restorable, history per row, locked rows read-only with reason, specific confirms, safe CSV | Done |
| Vendor payments | Same as expenses; audit events were logged against the vendor, not the payment | Audit gap | Same fixes; events now logged against the payment | Done |
| Expense / payment forms | Only server errors; no running guidance | Wrong number | Live reasons, lock warning, confirm naming amount, payee, date and effect; locked expense opens read-only | Done |
| Bank reconciliation | Confirm/Clear had no prompt; a locked period raised an error page | Wrong action | Confirm text names both records; failures shown as a message; difference stated in words | Done |
| Chart of accounts | Archive prompt vague; "normal balance" unexplained; codes not links | Findability | Plain wording, archive effect stated, codes link to account page | Done |
| Accounts owed, Books health, Approvals, Bank statements, Snapshot | Raw `number_to_currency` / `USD 12.34` styles | Inconsistent figures | Shared money text on approvals, bank statements, snapshot; Accounts uses finance_money | Done |

## Pages reviewed, not yet reworked

| Page | Observation | Risk | Recommendation |
|---|---|---|---|
| Daily reconciliation, Day close, Follow-ups, Source documents | Done: shared header, one primary action in the header, repeated list buttons demoted, 15px minimum | Flow | Still dense inside sections; not yet checked in the browser |
| Books desk | Clear "Do this next" card; weekly/period steps good | Low | Keep; add money formatting where amounts appear |
| Cash forecast, Source reports, Period locks | Done: shared header; per-currency money kept deliberately | Low | none |
| Receipts | Done: shared header and money display (pages have no Finance menu by design; employees use them) | Low | none |
| Finance navigation | Takes most of a phone screen above the page title | Flow | Collapse to one disclosure on small screens |

## Findings reported, deliberately not fixed (accounting logic)

1. Vendor payments and sales are posted to the ledger only by `Finance::Posting.backfill!`; nothing calls `Posting.vendor_payment` or `Posting.sale` when they are recorded or removed. The ledger and reports can lag the payments register.
2. Recording or restoring an expense saves the record, then raises (404) if the chart of accounts has not been seeded, leaving an expense with no ledger entry. The chart is only seeded when someone opens Chart of accounts.
3. Editing an expense voids its ledger entry and re-posts, rather than reversing it. Voided entries vanish from reports.
4. A statement line can be matched to a journal entry that is already matched to another line, and "Difference" compares totals over a window rather than matched items.
5. Account type and normal balance can be edited on an account that already has postings.
6. Expenses and vendor payments have no created_by/updated_by columns; history comes from the activity log, so older records show "author not recorded".
