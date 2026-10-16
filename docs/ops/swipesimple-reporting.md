# SwipeSimple website reporting on demand and every 30 minutes

Updated October 16, 2026 UTC. The owner authorized direct website pulls on SER8, on demand and every 30 minutes. No provider emails or payment/account-setting changes are part of this integration. Credentials, merchant identifiers, customer/operator fields, source files and session data are excluded from Git.

The earlier native importer release is recorded in the [initial deployment receipt](https://github.com/techmore/rupert/blob/codex/ser8-swipesimple-release/docs/ops/deployment-swipesimple-2026-10-15.md). [Partner-feed and long-term gateway research](swipesimple-integration-research.md) remains background context; the website pull described here is now the implemented automatic path.

## Access and verified website flow

SwipeSimple [does not publish a public integration API](https://support.swipesimple.com/hc/en-us/articles/27117544574487-Does-SwipeSimple-have-a-public-API-for-integrations). Rupert uses the authenticated website export flow. This is a working merchant website integration, not a vendor-supported partner API contract; website changes or additional authentication may require maintenance.

An independent fresh HTTP session from SER8 completed the CardFlight sign-in and downloaded both full exports. The browser's hidden cookies/storage were not read or copied. Every pull creates another memory-only session using the encrypted, owner-provided website login.

1. GET SwipeSimple `/sign_in` and its sign-in redirects to `login.cardflight.com`.
2. Read `/api/v1/login/context` for that fresh authorization return URL; POST only the native email/password/clientId form to `/api/v1/login`.
3. Follow the successful authorization callback back to SwipeSimple. Verify the company ID against company links on the authenticated Transactions page.
4. GET unfiltered `/transactions.json` and `/invoices.json` for native total and filtered counts. Require matching totals below 10,001.
5. GET new `/transactions.csv` and `/invoices.csv` with `time_zone=America/New_York`, with no date/search filters. Require each CSV row count to equal its website total. Reject login pages, unexpected content types, unknown schema and mixed merchant accounts.
6. Validate both files before a single database transaction publishes them. Preserve source-native transaction/refund identity and full invoice snapshots. An unchanged, freshly downloaded document updates the connection's successful-read time without storing another identical copy.

Only HTTPS requests to the two known service hosts and specific login/report paths are allowed. The provider currently emits one HTTP URL for its login-page redirect; Rupert upgrades that exact GET to HTTPS and never sends an HTTP request. Cookies remain host-isolated and in memory. Redirects to other hosts, TLS errors, invalid company identity, oversized documents and changed row totals fail safely. The network budget is bounded; errors contain fixed messages rather than upstream content or authentication URLs.

Incorrect credentials or an additional verification step set `Needs login` and pause automatic attempts. The owner can update the existing login and restore the schedule in POS & payment connections. Rupert never resets a password, solves a challenge, contacts the provider, changes API keys, processes a payment, or sends an invoice/receipt.

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

## SER8 setup and scheduling

The production application is `/opt/rupert/web` in the SER8 `rupert` Incus instance. Use the existing `rupert-jobs` Solid Queue worker and its scheduler. `swipesimple_web_pull` invokes `SwipesimpleWebSyncJob` every 30 minutes and fans out only to active workspaces with an authorized, enabled saved login. The dashboard's **Sync now** queues a real website pull for the current workspace, including when its schedule is paused. The dashboard shows the actual completed HTTP-read time, last stored row counts, and Live / Syncing / Stale / Error / Paused / Needs login.

In POS & payment connections → SwipeSimple, use production, the numeric company ID from the dashboard URL, and the existing website email/password. Credentials are encrypted in `PosConnection`, never echoed into forms or job arguments. No new deployment environment secrets, browser runtime, API keys, or second scheduler are required. Exports are interpreted as USD and America/New_York, matching the verified merchant context. Another currency or time zone needs explicit connector support before onboarding.

Preserve `/etc/rupert.env` and the application's existing encryption keys. Back up SQLite consistently and rehearse against a copy before deployment. Rebuild assets and restart the existing worker to load the changed recurring configuration. Verify an actual queued manual pull and a scheduled invocation, rather than treating a recurring entry alone as acceptance.

## Optional legacy inbox

`SwipesimpleInboxJob` remains available for explicit trusted-producer intake, but it is no longer the scheduled or dashboard pull path. `RUPERT_SWIPESIMPLE_INBOX` is optional and is not needed for webpage sync. Configure only an app-owned mode-0700 directory if using it separately.

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

## Release, verification and recovery

Keep a consistent private SQLite/configuration backup and preserve existing encryption keys. Verify tenant isolation, encrypted storage, atomic two-file publication, full native counts, repeated fresh downloads, source badges, manual queueing and the 30-minute recurring entry. The integration has tests for identity mismatch, changed setup during a request, malformed/truncated responses, verification pauses, concurrent pulls and unchanged-content deduplication.

A manual or scheduled pull failure retains prior snapshots and the last successful HTTP-read timestamp. The activity log and connection show a sanitized reason. Login failures pause the connection; network or schema failures retain the schedule for the next bounded attempt. To disable automatic pulls, clear the connection's schedule checkbox. Keep retained receipts and encryption keys when rolling back application code. No Authorize.net key is required or changed by this integration.
