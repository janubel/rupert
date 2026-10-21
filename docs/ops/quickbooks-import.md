# QuickBooks import and the History view

Status: design and operating notes for the QuickBooks CSV import (Bookkeeping → Records → **QuickBooks import**) and the **History** view that shows every retained source on one page. Written 2026-10-21.

Real QuickBooks exports, company names, account numbers, customers, vendors and amounts must never be committed, pasted into chat or used in tests. Tests use the synthetic files in `web/test/fixtures/files/quickbooks/`.

## What Rupert already had (inventory)

| Need | Existing piece | Notes |
| --- | --- | --- |
| Retained originals | `ReconciliationDocument` / `ReconciliationEvidence.retain!` | Append-only, encrypted, SHA-256 checked. Limited to **366 days per document** and 8 MiB, with a fixed list of sources, so it cannot hold a multi-year accounting export. QuickBooks therefore has its own `import_source_documents` (same properties, no period cap). |
| Reviewable import | `BankStatementImport` | The model for this work: byte-for-byte original, per-line fingerprints, no silent guessing, person decides. |
| Chart of accounts | `accounts` / `Finance::Account` | Code is unique per workspace; code, type and balance side are frozen once an account has ledger lines. |
| General ledger | `journal_entries` / `journal_lines` (`Finance::JournalEntry`) | Balanced, one-sided integer-cent lines, posted → void only, unique `(tenant, source_type, source_id)` while posted. `LockedPeriodGuard` refuses any entry dated in a locked period. |
| Period control | `PeriodLock`, `BookApproval` | Hash-chained lock/approval ledgers. Locks block writes; approvals only show as "changed". |
| Vendors | `vendors` / `Purchasing::Vendor` | Unique name per workspace. |
| Customers | `customers` / `Core::Customer` | Sources are an allow-list; "matching contact details never imply identity". |
| Bills / invoices | None as tables | Rupert has purchase orders and vendor payments, but no bill or invoice records. QuickBooks bills, invoices, deposits and checks arrive only as **journal transactions**, which is how they are posted. |
| Sales-to-ledger | `docs/finance-ledger-posting-plan.md`, issue #204 | Open decision: historical backfill must be separate, dry-run first, operator-reviewed, skip locked periods. This import follows that rule. |
| Source coverage | `Finance::SourceCoverage`, `docs/ops/historical-records.md` | Only four sources, date ranges only. Replaced for the whole picture by **History**. |
| `LedgerEntry` | 365-day mirror of orders | Not an archive (`DataRetention` prunes it). History reports canonical orders, not the mirror, and says so. |

## Standard QuickBooks exports (what is verified and what is not)

QuickBooks documents no fixed CSV layout for report exports. What follows separates what a source supports from what is assumed. **Anything marked unverified needs a sanitized sample file before it is relied on.**

| Export | Online / Desktop | Columns Rupert looks for | Sources and status |
| --- | --- | --- | --- |
| **Journal** (report) | Both | Date, Transaction Type (or Type), Num, Name, Memo/Description (or Memo), Account, **Debit, Credit**; Desktop adds Trans # | Desktop column set: [MindBridge guide](https://support.mindbridge.ai/hc/en-us/articles/6112217202839) (Trans #, Type, Date, Num, Name, Memo, Account, Debit, Credit). The Online export is Excel-first; Intuit and third parties describe saving as CSV ([Intuit export help](https://quickbooks.intuit.com/community/reports-and-accounting-5/export-reports-50306)). Exact Online CSV headers, a leading blank column, title rows, "TOTAL" and timestamp footers, and whether continuation lines leave Date/Type/Num blank are **unverified**; the parser tolerates each and reports which it assumed. |
| **General Ledger / Transaction Detail by Account** | Both | Date, Type, Num, Name, Memo, Split, Account, **Amount** (single signed column) | The Amount column "shows the natural sign of the amount (whether it increases or decreases the account)" ([Intuit community](https://quickbooks.intuit.com/community/reports-and-accounting-5/transaction-detail-report-net-amount-column-60042)), so it is **not** debit/credit and cannot be posted safely. Intuit documents customizing the report to show separate Debit and Credit columns ([Intuit](https://quickbooks.intuit.com/learn-support/global/reports/create-a-report-that-shows-debits-and-credits-for-each/00/381958)); such a file is read like a Journal. A single-Amount file is **refused with that explanation**, never guessed. Section heading rows and "Total for …" rows in these reports are unverified. |
| **Chart of Accounts / Account List** | Both | Full name or Account or Name, Type, Detail Type, Number (Account #, Accnt. #), Description, Balance | Online "Account List" report; Desktop "Print List" to a comma-delimited file or Account Listing exported to Excel ([MarginEdge guide](https://help.marginedge.com/hc/en-us/articles/27389289797267-How-to-Export-your-COA-from-Quickbooks-Desktop), [Intuit](https://quickbooks.intuit.com/learn-support/en-us/banking/export-import-a-chart-of-accounts/01/199759/highlight/true)). Exact headers and whether sub-accounts appear as `Parent:Child` are **unverified**. |
| **Vendors / Customers** | Both | Vendor or Customer (or Display Name, Name), Company Name, Email, Phone, address columns | Online "Vendor/Customer Contact List" reports; columns vary with the report customization ([Intuit](https://quickbooks.intuit.com/learn-support/en-us/manage-lists/import-export-csv-files/00/201366)). Only the name is used; contact details stay in the retained file. |
| **Trial Balance** | Both | Account, Debit, Credit | Online report shows only Debit and Credit columns; the export is Excel-first ([Intuit community](https://quickbooks.intuit.com/community/reports-and-accounting-5/trial-balance-report-35131)). Used for reconciliation only; the person enters the as-of date. |
| **Profit and Loss / Balance Sheet** | Both | Indented sections, "Total for" rows | QuickBooks Online has no direct CSV export of P&L ([Intuit](https://quickbooks.intuit.com/learn-support/en-us/reports-and-accounting/export-reports/00/1277391)), and indentation carries meaning that CSV loses. **Not imported in this release**; the Journal and Trial Balance cover reconciliation. |
| **Bills, Bill Payments, Invoices, Payments, Deposits, Checks/Expenses** | Both | — | Not separate imports. They are transaction types in the Journal ("Bill", "Bill Payment", "Invoice", "Payment", "Deposit", "Check", "Expense"). Rupert keeps the type and number on the imported transaction. AR/AP aging and open-balance reports are not imported. |

Also unverified, and handled defensively: date format (the parser reads `MM/DD/YYYY`, `M/D/YY` and `YYYY-MM-DD`, month first, and rejects `25/01/2024`); US number format only (a semicolon-delimited export is refused as probably decimal-comma); encoding (UTF-8 with or without BOM, UTF-16 with BOM, otherwise Windows-1252 with a notice). Memo, Class and Location are kept when present: memo goes to the journal line, Class and Location stay on the staged line. Split-line behavior: each line of a transaction is its own row, grouped by Trans # when present, else by the blank-date continuation rule, else by consecutive identical date/type/number/name; the grouping used is stated in the preview and every transaction must balance.

## Rules this import keeps

1. **Retain first.** Every upload is kept byte for byte, encrypted, with a SHA-256 checksum, before anything else. Re-uploading the identical file returns the same batch.
2. **Stage, preview, then approve.** Parsing writes only `import_*` rows. The batch page shows row, transaction, duplicate and rejected counts, the date range, totals by account, unbalanced transactions, unmapped accounts and every rejected row with its reason (downloadable as a formula-safe CSV).
3. **Explicit mapping.** Each QuickBooks account, vendor and customer needs a recorded decision: map to an existing Rupert record, create a new one on approval (accounts need a code and type; vendors need a unique name; customers are never created), or skip. A similar existing account is shown as a suggestion only.
4. **Never rewrite approved history.** Approval posts new entries only. A transaction is held, with the reason on it, when it is dated after the chosen last date, falls in a locked period (never unlocked by the import), uses a skipped account, resembles an earlier import, or lands in an approved day or week unless the person acknowledges that. The suggested last date is the day before Rupert's own first posted entry, so QuickBooks and Rupert never both record the same days unless the person decides so.
5. **Idempotent.** Transactions are fingerprinted by content (date, type, number, name, and the sorted account/amount/memo/class/location of each line), not by Trans #, so overlapping exports skip what is already staged or posted. A same-number transaction whose lines differ is held as "resembles", not double counted.
6. **Reversible by batch.** Reversal voids every entry the batch posted (all or nothing; refused while any sits in a locked period) and frees the fingerprints. Originals and staged rows stay as evidence. Accounts and vendors created on approval are not deleted.
7. **Exact money and dates.** Integer cents; amounts with more than two significant decimals are rejected, never rounded. Dates are calendar dates with no time-zone shift.
8. **Access.** Viewing needs finance read; uploading, mapping, approving, discarding and reversing need finance write (store administrators by default). All are tenant-scoped, logged to the activity log, and limited to 10 MiB and 30,000 rows.

## Tables (migration `20261022020000_create_history_imports`)

- `import_source_documents`: the original file (no period cap). Append-only.
- `import_batches`: one reviewed import of one file, with counts, summary, status (`staged`, `approved`, `discarded`, `reversed`) and who approved or closed it.
- `import_transactions`: one balanced group of lines; `journal_entry_id` links the imported record back to the books, and the entry's `source_type`/`source_id` (`ImportTransaction`) link forward to the batch.
- `import_lines`: one parsed row (transaction line, account, vendor, customer or trial-balance row), money in cents, names/memos/raw row encrypted.
- `import_entity_mappings`: the person's decision for each outside account, vendor or customer.

The down migration refuses to run while any retained document exists, as earlier evidence migrations do.

## Operating it

1. Export from QuickBooks as CSV (Online: report → Export as CSV; Desktop: Excel → Create a comma separated values file). Prefer a Journal covering the whole history in one or a few files.
2. Upload the **Chart of accounts**, review, create or map each account, approve (this only creates accounts you chose to create).
3. Upload the **Journal**. Map any accounts not yet decided. Read the preview. Choose the last date to post (default: the day before Rupert's own first entry) and approve.
4. Upload a **Trial balance** as of a date to check the result on the History page.
5. If something is wrong, reverse the batch with a reason, fix the export and upload again.

Do not import anything into production from a development machine. Take the usual database backup first (autodeploy already does before migrations; an import is a business decision, so check **Settings → Backups** is current).

## History view

The History page (Bookkeeping → Records → **History**) arrives in a second change set; this document is extended there.
