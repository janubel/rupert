# SwipeSimple tax/sales reports and items pull

The SwipeSimple website pull (`SwipesimpleWeb::Sync`, every 30 minutes via
`SwipesimpleWebSyncJob`) signs in once and reads, in order:

1. the transactions and invoices exports (unchanged; if these fail, the whole pull fails as before);
2. **Reporting → tax** and **Reporting → sales** CSVs for a rolling window: the
   calendar months covering at least the last 45 days (store timezone
   America/New_York), one request per month;
3. the **items workbook** (`items.xlsx`).

Steps 2 and 3 are isolated: if either fails, the transactions/invoices result is
still saved, the pull stays `succeeded`, and the connection message says
"Tax and sales reports were not updated: …" or "Items were not updated: …".
Previously stored report days and the previous item list are kept.

Everything is read-only toward SwipeSimple: GET requests only, to the exact
paths `/companies/<company id>/reports.csv` (the connection's verified company
only) and `/items.xlsx`, with the client's existing host allow-list, time
budget, size limit and per-session cookie isolation.

## Reports

Request: `GET /companies/<id>/reports.csv?report[topic]=tax|sales&start_date=YYYY-MM-DD&end_date=YYYY-MM-DD`.
Other parameter names are ignored by SwipeSimple (it falls back to the last 30
days), so only these are sent and every returned date is checked.

Each month's CSV is rejected as a whole unless:

- the headers match exactly
  (tax: `Date, Tax Rate, Pre-Tax Subtotal, Total $ of Sales Tax, Total $ of Sales`;
  sales: `Date, Subtotals, Discounts, Sales Taxes, Tips, Refunds, Total Net Sales, Total Net Card, Total Net Cash`);
- the last row is `Totals` and every other row is an `MM/DD/YYYY` date inside the requested month;
- no day (tax: day + rate label) repeats;
- every money cell is a plain amount (`$`, thousands commas, minus or parentheses allowed; blank = unknown, never zero);
- for every money column the day rows add up exactly to SwipeSimple's Totals row.

Storage (tenant-scoped):

- `swipesimple_tax_days` — one row per day and tax rate label (`rate_percent` parsed from labels such as `PA Tax Rate (6.0%)`, nil for `No Tax`);
- `swipesimple_sales_days` — one row per day (all amounts in cents, nullable);
- `swipesimple_report_pulls` — the range each CSV covered, its digest and the raw CSV (encrypted).

A re-pull replaces that month's days and coverage record in one transaction.
Days with no sales are absent from SwipeSimple's CSV; a covered day without a
row therefore had no sales, while a day outside every pull is unknown. Months
that have ended are also retained as reconciliation evidence
(`ReconciliationDocument`, source `swipesimple`, kind `processor_report`); the
still-changing current month is kept only on its pull record.

The merchant account is the single account verified by the transactions export.

### Sales tax report

Reports → Sales tax shows one SwipeSimple line per merchant account from the
tax report: tax collected = sum of `Total $ of Sales Tax`, sales before tax =
sum of `Pre-Tax Subtotal`, gross = sum of `Total $ of Sales`. The note splits
taxable and not-taxed sales by rate label and states coverage ("cover N of M
days, pulled through <date>" when some days have not been pulled). Accounts with
no pulled tax report fall back to the transaction-export line and optional
estimate. The two are never shown together and sources are never added.

`swipesimple_sales_days` is available for a later daily-close view.

## Backfill (owner-run, once)

Not run on deploy. Pulls month by month with a pause (default 2 s) between requests:

```sh
bin/rails "swipesimple:backfill_reports[2025-01-01,2026-10-19]"
# optional: TENANT_ID=<workspace> when several workspaces have SwipeSimple; PAUSE=<seconds>
```

The end date defaults to yesterday and cannot be in the future; ranges are
limited to about three years. A transaction pull must have run first so the
merchant account is known. A failure stops the run and keeps every month already stored.

## Items

`items.xlsx` has sheets `Instructions`, `Items` and `Taxes`, located by name
through the workbook relationships. Headers must match exactly
(`id, name, sku, price, tax, status, track_inventory, on_hand_count, category` and
`id, name, value`). Removed items are left out. Stock is set only when
`track_inventory` is true; otherwise it is unknown, never zero. Each item's tax
label is resolved to a rate via the Taxes sheet (a "No Tax"-style label is 0%).

The records replace the account's `SwipesimpleItemSnapshot` only when the
workbook bytes change, so the SwipeSimple items page and matching work
unchanged. The page shows "Pulled automatically at …" and a Tax column; the
manual CSV upload remains as a fallback.
