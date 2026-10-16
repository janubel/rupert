# SwipeSimple read-only reporting and SER8 hourly intake

Investigated October 15, 2026; status updated October 16. The owner subsequently authorized merging [PR #47](https://github.com/techmore/rupert/pull/47), deploying to SER8 and importing the downloaded native files. That release and validation are recorded in the [deployment receipt](https://github.com/techmore/rupert/blob/codex/ser8-swipesimple-release/docs/ops/deployment-swipesimple-2026-10-15.md). Manual native CSV imports are working; hourly intake remains disabled pending a supported vendor feed. No merchant payment operation, invoice/receipt delivery, merchant-setting change or inventory write was performed. See the [expanded integration research](swipesimple-integration-research.md) for current options, ACH gaps and the long-term Valmar/Authorize.net objective.

## Verified access and the remaining vendor dependency

The authenticated merchant portal exposes Transactions, Invoices, Reports and Account Settings. Native transaction and invoice CSV files were actually downloaded and validated privately. The account's plan is Payments and its configured time zone is Eastern. Only the configuration was read. Credentials, merchant identifiers, customer/operator fields, source files and financial totals are excluded from Git.

| Access path | Evidence | Conclusion |
| --- | --- | --- |
| Public reporting API | [Official public API statement](https://support.swipesimple.com/hc/en-us/articles/27117544574487-Does-SwipeSimple-have-a-public-API-for-integrations), reviewed October 15 | No public API offered. Merchant login does not establish API entitlement. |
| Partner API | Current [reseller resources](https://home.swipesimple.com/resellers) and [Partner Content Hub](https://home.swipesimple.com/content-hub) provide partner routes, not a merchant reporting specification | Earlier RAMP/onboarding references do not establish current reporting access. Merchant reporting authorization, endpoint contract and credentials were not established for this account. |
| Native transaction export | [Official export instructions](https://support.swipesimple.com/hc/en-us/articles/360011804593-How-do-I-export-my-transactions) and actual authenticated CSV | Supported fallback; maximum 10,000 transactions per vendor export. Filters affect export contents. |
| Native invoice export | [Official invoice guide](https://support.swipesimple.com/hc/en-us/articles/360019039554-Invoices-on-Web-How-To-Guide) and actual authenticated CSV | Supported. Invoice numbers demonstrably repeat, so a number is not a unique vendor invoice ID. |
| Scheduled reporting | [Official batch/daily report guide](https://support.swipesimple.com/hc/en-us/articles/360011707534-Batch-Reports-Daily-Transaction-Reports); live Reports settings expose recipients | Daily/batch email reporting is supported. An hourly machine-readable feed, attachment schema, SFTP delivery or webhook was not established. Recipient configuration was not changed. |
| App Marketplace | Current [SwipeSimple website](https://home.swipesimple.com/) advertises specific applications | Specific vendor integrations do not establish a general reporting API for Rupert. The older broad third-party-integration wording in support documentation should not be generalized beyond the public API finding. |

**Smallest vendor action:** ask the existing merchant service provider to confirm an approved read-only hourly transaction and invoice feed for this account, with its export/API contract and delivery mechanism. No new merchant password is needed for the CSV importer. The suggested request is below; it has not been sent.

> Please confirm whether our SwipeSimple Payments account supports an approved read-only reporting API or automatic CSV delivery at least hourly. We need transactions, refunds, payment results, invoice status and tips, ideally stable internal transaction/invoice IDs, refund-to-sale links and original document references. If access is partner-only, identify the sponsoring partner and authorization process. Please supply the supported schema, time zone/currency rules, pagination/retention limits and delivery/authentication documentation. We are not requesting payment-write access or merchant-setting changes.

The hourly worker in this change ingests delivered local exports. It does not obtain fresh files from SwipeSimple. Running it hourly without a supported producer does not provide hourly sales freshness.

## Native formats actually observed

Transaction CSV begins with an optional UTF-8 BOM and these vendor headers:

```csv
Transaction #,Date,Type,Amount,Result,Method,Brand,Last 4,Auth Code,Cardholder Name,Reference Number,Merchant Account,Taken By,Tip Amount
```

The official demo export omitted `Tip Amount`; the live export included it. Both forms are supported. Core transaction headers are required; recognized optional vendor columns are accepted without renaming. Unknown/duplicate headers are rejected so schema drift is visible. Native timestamps are local `M/D/YYYY h:mm AM/PM`, without an offset. Amounts use dollars and exactly two decimal places, optionally with a dollar sign and thousands separators. Only explicitly confirmed USD is supported.

Invoice CSV headers are:

```csv
Invoice Number,Customer,Date Created,Last Sent,Due Date,Status,Amount
```

Invoice date/time fields follow the same local timestamp format. Due Date is `M/D/YYYY`; Last Sent and Due Date can be blank. The CSV does not include the internal invoice URL/ID or merchant account, so the operator must confirm the account context. The importer requires confirmation that this is a **complete, unfiltered invoice export**. Date, search and status filters must be removed before download. A confirmed empty complete invoice export is accepted as an empty current invoice snapshot; prior evidence remains retained.

`web/test/fixtures/files/swipesimple_transactions.csv` and `swipesimple_invoices.csv` preserve the actual vendor headers, formatting and status shapes observed in the official demo. All identity/contact/card-authorization values in those fixtures were replaced with fictional values. They are not merchant exports. Private live files were checked separately without copying their contents into test fixtures.

## Field meaning and reporting behavior

| Need | Working behavior | Evidence limit |
| --- | --- | --- |
| Sales | Approved Sale transactions retain processed amount and event timestamp | No inferred merchandise lines, taxes, discounts, costs or inventory deductions. |
| Refunds | Approved Refund transactions retain their own date, amount, result and tender evidence | Linked original-sale IDs are omitted from the native transaction CSV. No guessed linkage or refund application. |
| Payment status | Approved, Declined, Voided, Errored and Canceled are preserved | Errored/Canceled can have uncertain processor outcomes. Only Approved enters recorded payment totals; approval is not bank settlement. |
| Cash/card totals | Latest transaction observations grouped by Eastern event day, account, currency and cash/card/unknown tender | Card entry modes or an exported recognized card brand establish card evidence. Invoice/Payment Link alone cannot exclude ACH, so missing card evidence remains unknown. |
| Tips | Sale and refund tips shown separately and already included in processed Amount | Tips are never added to Amount a second time. Missing tip evidence remains unavailable, not zero. |
| Invoices | Latest complete account snapshot preserves all source rows, amounts, dates and statuses | Invoice amounts are not additional collected sales. “marked as paid” does not establish tender or collection time. |
| Invoice/payment association | Exported Reference Number is retained; invoice-method reference may contain invoice number | Numbers can repeat. No automatic relationship or unique vendor ID is invented. |
| Original IDs/documents | Source number, export ID, source row, file SHA-256, snapshot/export time and importer attribution retained; exact original CSV downloadable | The displayed transaction number differs from the opaque ID in portal detail URLs. Receipt history, receipt PDFs, invoice documents and linked refunds are not exported. No guessed source URLs. |
| Inventory | No inventory actions | C-Trax remains the retail inventory reference; prepared item CSVs and this source report are separate workflows. |

Source transaction identity uses merchant account, currency, transaction number and Sale/Refund type. The official demo demonstrated a Sale and Refund with the same displayed transaction number; treating that number alone as the identity would lose data.

Invoice numbers are not unique in the live export. Each full invoice snapshot therefore preserves each row as evidence and the report selects the latest whole snapshot for its account. Invoice rows are not merged across files using a fabricated vendor ID. Row positions identify evidence inside an export only.

Both kinds retain immutable export history. Selection uses the operator-confirmed `exported_at`, never import completion time. Late older exports cannot revive a newer void or invoice status. Equal-time conflicting evidence is rejected. Transaction overlap is de-duplicated in reporting, while each original file remains available for audit. A repeated identical file with the same context returns the existing receipt.

These totals are a view of the latest evidence currently supplied, not a historical close frozen as of a past day. A subsequent void can change a past day's displayed total. Missing transactions or a missing day's export do not prove zero sales. Keep processor/batch and bank reconciliation separate.

## Manual review/import

After an approved deployment, open `/swipesimple_reports`, also linked from Sync's existing SwipeSimple section.

1. Export native Transactions for one merchant account, or all Invoices without filters. Vendor transaction filters are sticky and the default view covers only the last 90 days. Choose the intended range deliberately; split history into ranges below the vendor's 10,000-transaction limit.
2. Confirm kind, exact merchant account, USD, source IANA time zone and actual file export time with seconds and explicit offset. For this account the observed zone maps to `America/New_York`. Do not substitute today's import time for an old file's unknown export time.
3. Preview. The entire file is validated; aggregate counts/results/amounts are shown without customer data. No source report, canonical sale, ledger, customer, sync run or inventory record is saved.
4. Compare the preview against SwipeSimple. Reattach the same file and import within 15 minutes. The signed preview binds exact file bytes and all context to the current tenant and reviewing user. Changed, expired or foreign-user previews are rejected.
5. Inspect the daily cash/card/tip report, latest invoice observations and source-document receipt. Large detail lists are visibly limited to 200 rows; totals use the full selected day. The 20 most recent receipts are shown. All retained history remains in the database.

Report pages require `reports.read`. Preview/import and original-document downloads require `sync.write`. Original downloads contain customer and operator columns and are not available to readers. Responses use `no-store`; uploaded files/context and sensitive row fields are filtered from request logs. Original documents, source numbers and reference numbers use existing Active Record encryption. Production encryption keys remain required and must be preserved with backups.

Bounds: 8 MiB, 10,000 data rows, 4,096 bytes per cell; strict known headers, cell counts, UTF-8 and control-character checks; nonnegative two-decimal amounts within the database integer limit. Whole-file validation precedes writes. Ambiguous/nonexistent daylight-saving local times are rejected for source clarification. Unknown results/statuses and inconsistent account/time-zone context are rejected without echoing source contents. Business changes are atomic per file. Invoice status changes and transaction void/result changes remain versioned observations.

This importer writes only `swipesimple_exports` and `swipesimple_report_rows`. It deliberately does not feed the existing Core::Order/Ledger stream, because native reports do not establish item lines and may overlap previously prepared item CSV imports. It also does not emit sales announcements, email, payment requests or stock movements.

## SER8 target and hourly intake

Tailscale SSH inspection confirmed the existing SER8 host and running `rupert` Incus instance. The owner-authorized release installed this reporting code and imported the native files; see the linked deployment receipt for the release revision and validation. Existing integrations were preserved in the combined release. `RUPERT_SWIPESIMPLE_INBOX` remains unconfigured, and the job returns `disabled`. No vendor producer is installed.

The existing Solid Queue worker is the intended scheduler. The `config/recurring.yml` entry invokes `SwipesimpleInboxJob` **every hour at minute 20**. Preserve the existing schedules for other integrations. No desktop Codex reminder or second production scheduler is required. With the inbox variable absent, the job returns `disabled` and performs no intake.

Only after a supported producer is verified and hourly activation is authorized, configure an app-owned persistent directory such as `/opt/rupert/web/storage/swipesimple-inbox` (mode 0700), and set in the protected deployment environment:

```text
RUPERT_SWIPESIMPLE_INBOX=/opt/rupert/web/storage/swipesimple-inbox
```

Use existing `/etc/rupert.env` and `deploy/rupert-jobs-ser8.service`; do not put vendor credentials in manifests or source control. Do not replace production paths with the laptop's `rupert-dev` test paths. Normal release restart/reload is required for recurring configuration changes. Existing production encryption keys protect retained exports; do not generate replacement keys during deployment.

A trusted producer writes a completed CSV first, then atomically renames a manifest into `*.ready.json` in that directory. Example (fictional values):

```json
{
  "tenant_id": "REPLACE_WITH_EXISTING_WORKSPACE_ID",
  "kind": "transactions",
  "merchant_account": "Example Wholesale",
  "currency": "USD",
  "source_timezone": "America/New_York",
  "exported_at": "2026-10-15T20:30:00-04:00",
  "csv": "transactions-20261015-2030.csv",
  "sha256": "REPLACE_WITH_64_LOWERCASE_HEX_SHA256_OF_EXACT_CSV_BYTES"
}
```

For invoices set `kind` to `invoices` and add `"invoice_scope": "full"`. This is an operator/producer assertion of full unfiltered coverage; it cannot be recovered from CSV bytes. The producer must supply the actual export time and account context. The worker does not derive them from a filename, mtime, customer name or import time.

The SHA-256 is an integrity check, not a signature or authorization mechanism. The directory's write access is privileged: a producer can select a tenant, so only a trusted deployment operator/approved producer may write there. Require plain CSV basenames, regular bounded files and no file symlinks. The job takes a nonblocking directory lock, allows at most 100 pending manifests, verifies exact bytes and validates all rows. An inactive/missing tenant, bad digest, traversal, symlink or malformed export fails safely. Error logs contain a fixed message, not source values or manifest content.

Successful manifests become `*.imported.json`; CSVs remain locally and exact original contents are also encrypted in receipts. A crash between database commit and rename replays safely. A later failure does not roll back earlier files already committed in that invocation. Failed manifests stay pending for private operator review. Retire acknowledged local files through the approved retention procedure after verifying encrypted receipts and backups; the implementation performs no automatic document deletion.

Monitor **both** job failures and source freshness. Check the newest receipt's export time, import time and newest stored transaction event separately. An empty inbox or a successful replay is not evidence that new vendor data has arrived. No source coverage watermark or processor settlement confirmation is fabricated.

## Release and rollback checklist

- Initial deployment/import is complete under the owner's subsequent authorization. Review future changes and activation through the normal release process.
- Preserve a consistent production SQLite backup and existing encryption/configuration keys. Rehearse migration/rollback on a separate copy, retain preexisting business data, and confirm schema/foreign-key integrity.
- Apply the two-table migration only after approval. Start with manual exports and compare counts/tenders/tips/statuses privately against the same vendor range.
- Enable the hourly inbox only when an approved producer is actually delivering verified files. Observe at least two arrivals and verify newest export time advances; an hourly scheduler alone is not acceptance.
- If intake fails, unset `RUPERT_SWIPESIMPLE_INBOX` and reload the jobs configuration through the normal approved release procedure. Keep receipts and keys; reverting code need not discard imported evidence.

## Verification record

The implementation has dedicated service, controller and job tests for actual vendor-format shapes with fictional data, encrypted provenance, exact replay, overlapping transactions, Sale/Refund identity collision, duplicate invoice numbers, complete/empty invoice snapshots, newer/older status selection, daily totals, missing tips, uncertain tenders, tenant/user authorization, private downloads, token expiry/context tampering, strict parsing and inbox integrity/path defenses.

The official merchant exports were previewed and then imported privately under the owner's deployment authorization. The linked release receipt records production installation, encrypted original-byte checks, replay checks and independent source-to-daily-total reconciliation. Neither that verification nor fixture tests establish bank settlement, API entitlement, all-time completeness or automatic file delivery. Test/lint results are recorded in the implementation PR and release receipt.
