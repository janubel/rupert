# Plan: post sales and refunds to the ledger live

Status: **decided by the owner (2026-10-21, issue #204) and implemented in the sales-posting change.** Vendor payments are a separate step (see the end). Nothing here is run against production data until the owner confirms the dry runs.

## What was true before this change

- `Finance::Posting.expense` ran when an expense was recorded, edited, removed or restored.
- `Finance::Posting.sale` had no caller. Production nevertheless held 11,550 posted `sale` entries, all created in one batch on 2026-10-17 (a console `Posting.backfill!`), for 11,573 completed payments. The 23 payments after that batch were unposted, and the gap grew with every sale.
- Every receipt, card included, was debited to Cash 1000, so about $854K of card sales sat in Cash while the bank screen held 909 unmatched deposit lines.
- There were no refunds, tips or locked periods in production, so none of those paths had real data behind them.
- Sales are created in four places (`Pos::Checkout`, `WarehouseCheckoutService`, `SwipesimpleImporter`, `CanonicalOrderImporter`); imports can re-run and change a payment.

## Decisions

1. **Authoritative source and basis.** `Core::Payment` rows with status `completed` are the sales source, recognised when the payment is taken (cash basis for revenue). Sales tax is the payment's proportional share of its order's tax (tips excluded), as before.
2. **Card receipts go to `1150 Card settlements receivable`**, a new standard asset account, not Cash. Cash, gift card and "other" tenders still debit Cash 1000; check debits Checking 1100. Gift card and store credit have no liability account yet and are flagged below.
3. **Refunds** post their own entry (kind `refund`): debit `4200 Refunds` and `2100 Sales tax payable` (the refunded share of tax), credit the tender's receipt account. The original sale is never edited. Store credit and gift card refunds create or use a liability that has no account yet, so they are **not** posted automatically; they surface as unposted and need a manual journal entry. Discarding a refund voids its entry.
4. **Imports that change a payment**: the entry is voided and posted again, exactly as expenses are ("entries produced from a payment are corrected on that record"). A payment that stops being `completed`, or is deleted, loses its entry. Entries are never edited or deleted.
5. **Duplicates**: one posted entry per `(source_type, source_id)`; every posting call is idempotent.
6. **Failures never block the till or an import.** The hook runs after the payment commits; a refusal (a locked period, a missing account) is reported through `Rails.error` and leaves the payment unposted. Unposted records are counted in the notice on every finance report and listed by the backfill task.
7. **Historical backfill and reclass stay separate, dry-run first, owner-reviewed.** Neither changes anything without `CONFIRM=1` and an explicit `TENANT_ID`.
8. **Card settlements are not matched yet.** Until the processor's deposit (net of fees) is posted against `1150`, that account carries a balance. The report notice says so; that is the remaining accepted limitation.

## What was built

- Live hook: `Core::Payment` and `Core::Refund` call `Finance::Posting.sync_sale` / `sync_refund` after commit.
- `Finance::Posting.sale` and `.refund`, with the receipt-account rules above; `refund` is a new journal entry kind.
- `Finance::SalesBackfill` and `rake finance:sales:backfill`: unposted payments and refunds by month. Posts record by record and reports what a locked period or missing account refused.
- `Finance::CardReclass` and `rake finance:sales:reclass_card`: one dated entry per month moving card receipts still in Cash to 1150 (debit 1150, credit 1000). It works as a delta against earlier reclass entries, so re-running is safe. The dry run never seeds the chart.
- The standard chart gains 1150; an existing tenant gets it the first time something posts (the chart seed is idempotent and only adds missing codes).
- Report notice: now says card settlements are not matched yet, plus a count of payments and refunds still missing from the ledger.

## Running it on production (after owner review)

```sh
# dry runs: print only
TENANT_ID=<id> bin/rails finance:sales:backfill
TENANT_ID=<id> bin/rails finance:sales:reclass_card
# post, after reviewing the tables: backfill first, then reclass
CONFIRM=1 TENANT_ID=<id> bin/rails finance:sales:backfill
CONFIRM=1 TENANT_ID=<id> bin/rails finance:sales:reclass_card
```

Do this before any month is locked: locked periods refuse the entries, and the tasks report them rather than skipping silently. Run on a copy first. Remaining acceptance for #204: the owner-reviewed dry run tables, a representative sale/refund reconciled against its source (SwipeSimple or Square), and the recorded accepted limitation (item 8).

## Still open

- Vendor payments (`Posting.vendor_payment`) are not posted live yet; removing one does not void an entry. Separate change.
- Card settlement posting: match each processor deposit (bank statement line) to the sales it settles, post net deposit to Checking, fees to 6000 Bank & processing fees, and clear 1150.
- A liability account for store credit and gift cards.
