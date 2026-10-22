# Zelle reporting by manual bank CSV

Added October 21, 2026. Companion to [SwipeSimple reporting](swipesimple-reporting.md); the page lives at `/zelle_reports`, as the **Zelle** tab next to **SwipeSimple** on the payment-source report pages (and linked from Sync).

## What this is, and is not

Zelle has no public merchant or business API, and Rupert never signs in to a bank or stores bank credentials. Money sent with Zelle is received into a bank account, so the only evidence is a statement or transaction export from that bank. This feature is a **manual file import** of such an export.

- Entries are payment evidence with tender `zelle` and verification `unverified`. Nothing reconciles them automatically; a person still matches them to the bank statement.
- Zelle is its own source with its own daily totals (by bank posting date). It is never added to SwipeSimple cash/card totals, and it never creates a `Core::Order`, payment, ledger entry, customer, sync run or stock movement.
- No bank, merchant, Zelle or SwipeSimple setting is read or changed. There is no scheduled pull and no outbound network call.

## CSV contract (`zelle-bank-csv-v1`)

This layout is **an assumption** modelled on typical bank-statement exports; banks do not share one Zelle format. Export or copy only the Zelle rows from your bank, then arrange the columns (in a spreadsheet, saving as CSV UTF-8) into:

```csv
Date,Amount,Direction,Reference ID,Counterparty,Memo
2026-10-14,48.00,credit,EXAMPLE-0001,Example Customer,Order 1001
10/14/2026,"1,200.50",credit,EXAMPLE-0002,Example Customer 2,Wholesale deposit
2026-10-14,15.25,debit,EXAMPLE-0003,Example Vendor,Refund
```

| Column | Required | Rule |
| --- | --- | --- |
| `Date` | yes | Bank posting date, `YYYY-MM-DD` or `M/D/YYYY`. Not after the export day plus one. It is the business day for daily totals; no time zone is applied. |
| `Amount` | yes | Positive dollars with exactly two decimals; optional `$` and thousands commas. Zero and negative values are rejected. |
| `Direction` | yes | `credit` (money received) or `debit` (money sent), case-insensitive. The sign lives here, not in Amount. |
| `Reference ID` | yes | The bank's unique transaction/confirmation identifier (max 200 characters). Identity of an entry is account label + currency + this value. |
| `Counterparty` | no | Sender or recipient name as the bank shows it. |
| `Memo` | no | The Zelle memo. |

Header names are matched ignoring case. Unknown, duplicate or missing columns reject the file, so a changed bank layout is noticed rather than misread. Rows with no usable reference ID cannot be imported: without a stable ID, overlapping exports could not be de-duplicated safely.

Bounds: 8 MiB, 10,000 data rows, 4,096 bytes per cell, UTF-8 without null or control characters, whole-file validation before any write. Errors name the row number and a fixed reason; they do not echo file contents.

## Review and import

Operator-supplied context, as with SwipeSimple: a short **bank account label** (for example "Business checking 1234": last four digits at most, never a full account number), **USD** (the only supported currency), and the **file download time** with seconds and an explicit UTC offset (prefilled with the current time; correct it for an older file).

1. Open `/zelle_reports` (Zelle tab). Choose the file and context and select **Preview Zelle file**. The whole file is validated and only aggregates are shown (row count, received and sent counts and totals, date range). Nothing is saved.
2. Compare those totals to your bank. Reattach the same file and select **Import reviewed Zelle file** within 15 minutes. The signed preview binds the exact file bytes and context to the current workspace and reviewing user; a changed, expired, foreign-user or other-feature token is rejected.
3. Review the daily totals (received, sent, net) and the up-to-200 entries for the selected day. Every row is labelled `Zelle · unverified`.

Replay protection: the same file with the same context returns the existing receipt without adding rows. Overlapping exports of the same account are allowed; each bank reference ID counts once, taken from the export with the latest download time (a late older file cannot revive a replaced value). Two different statements of one reference at the identical download time are rejected as conflicting. A missing day does not prove zero Zelle payments.

## Security and privacy

- `reports.read` to view; `sync.write` to preview, import and download the original CSV. Readers never see the upload form or download links.
- Every query is tenant scoped (`TenantScoped`); another workspace gets 404 for a document id.
- Responses carry `Cache-Control: no-store` and `X-Content-Type-Options: nosniff`.
- The original CSV, bank reference ID, counterparty and memo are stored with Active Record encryption (the production encryption keys are required and must be preserved with backups). The account label and amounts are not encrypted, like SwipeSimple's merchant account and amounts.
- The uploaded file, `zelle_export` context, counterparty, memo and bank reference are in `filter_parameters`, so they do not reach request logs. Previews and error messages carry no counterparty, memo or reference values.
- Open downloaded CSVs as text: spreadsheet programs may execute formulas that appear in counterparty or memo cells.

## Tables

`zelle_exports` (immutable receipt: label, currency, SHA-256, fingerprint, download time, row count and date range, encrypted original) and `zelle_entries` (one row per bank reference per export, with `tender='zelle'`, `verification='unverified'`). Both are new; no existing table changes. Rolling back the application code leaves them in place.

## Open items for the owner

- Confirm the placement (a second tab on the payment-source pages, plus a Sync link) and the column layout above against your bank's actual export.
- Reconciliation of Zelle entries to deposits/bookkeeping is deliberately not built; the `verification` column exists so a later reviewed workflow can mark entries without changing history.
