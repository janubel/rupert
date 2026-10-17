# Plan: post vendor payments and sales to the ledger live (for owner approval)

Status: **proposal only. No posting rule or code has been changed.**

## What is true today (verified in code)

- `Finance::Posting.expense` runs when an expense is recorded, edited, removed or restored.
- `Finance::Posting.vendor_payment` and `Finance::Posting.sale` are **never called** by the app. `Posting.backfill!` is also never called (no rake task, job or controller). So vendor payments and sales reach the general ledger and reports only if someone runs it from a console.
- Removing a vendor payment does not void any ledger entry (it has none).
- Sales are created in four places: `Pos::Checkout`, `WarehouseCheckoutService`, `SwipesimpleImporter`, `CanonicalOrderImporter`. Imports can re-run and can change or cancel orders.
- `Posting.expense` raises if the chart of accounts is not seeded (seeding currently happens only when Chart of accounts is opened).

## Decisions I need from you before building

1. **Which sales count?** Only `Core::Payment` rows with status `completed` (current posting rule), or also refunds? Refunds have no posting rule yet.
2. **Card sales** post to Cash 1000 today and the bank screen says card settlement is a separate step. Keep that, or post card receipts to a clearing account?
3. **Backfill scope and date.** Backfilling history posts entries into possibly locked periods. Proposal: backfill only unlocked periods, list the locked ones for a decision, never touch locked months.
4. **Source of truth for imports.** If an import later changes a payment, should the entry be voided and re-posted (as expenses do) or reversed? I recommend reversal, which is the audit-friendly option and matches the new Reverse action.

## Proposed steps (each its own commit, each with tests)

1. **Safety first.** Seed the chart of accounts when a tenant is created and make every `Posting` call fail loudly inside the same transaction as the record it posts (record and entry succeed or fail together; no more saved expense with no entry).
2. **Vendor payments.** Call `Posting.vendor_payment` on create; on remove, void or reverse that entry (per decision 4); on restore, post again. Blocked inside locked periods, same as the record.
3. **Sales.** Post from a single hook on `Core::Payment` completion (after commit), covering all four creators. Idempotent: the existing unique index on `(source_type, source_id)` for posted entries already prevents doubles. Cancellations and refunds follow decision 1.
4. **Backfill with a dry run.** A rake task that prints counts and totals per month, skips locked periods, and only posts with `CONFIRM=1`. Run on a copy first.
5. **Reconcile the numbers.** A read-only check on Books health: for each month, ledger sales and vendor payments versus the registers, shown as "Balanced / differs by $X".
6. **UI.** Source links on entries already work; add "posted to ledger / not yet posted" status on the payments register.

## Risks

- Changing historical reports: backfilled months will change totals. Mitigation: dry run, locked months untouched, owner review of the per-month table before confirming.
- Double counting sales with expenses or card settlement: covered by decision 2 and the check in step 5.
- Nothing is sent to Shopify or Square; this is local database only.
