# NAB / IRIS merchant reporting

Investigated October 15, 2026, America/New_York. This integration preserves processor reports for reconciliation in Rupert; C-Trax remains the retail inventory reference.

Automatic native Daily Deposits website imports are enabled on SER8. The earlier six monthly Health Center snapshots remain separate visible-table transcriptions. See [deployment verification and remaining API access requirement](iris-deployment-2026-10-15.md). Live API authentication and native Health Center export formats remain unverified. The expanded [integration investigation](iris-integration-investigation.md) covers additional endpoints, native Daily Deposits CSV, documents, webhooks and delivery alternatives.

## Verified evidence and limits

- The signed-in NAB merchant portal exposes deposits, batches, authorizations, financials, retrievals, chargebacks and statements. Two merchant accounts were visible. Their identifiers and real financial records are deliberately excluded from public source.
- Sales Health Center and Transaction Health Center each expose **Export → CSV / XLS**. Their visible tables are monthly summaries, not individual payments. Sales Health includes gross, returns, net and a year-over-year percentage; Transaction Health includes return, chargeback and retrieval amounts/counts. These cannot substitute for transaction IDs or net bank reconciliation.
- Health Center native exports were requested through the portal, but this browser did not deliver their files. The importer supports the supplied template and the English table layout observed in the portal; an unknown native Health Center layout must be inspected before claiming compatibility. XLS is not parsed. A separate **Daily Deposits CSV** subsequently downloaded successfully and its structure/count/totals were inspected privately; this batch-level format has its own native importer and snapshot kind, separate from monthly summaries.
- Documents contains Dejavoo terminal quick-reference PDFs (retail/restaurant, dual pricing and cash discounts) and a TSYS funding-deadlines PDF. The funding PDF subsequently downloaded and was read: conflicting cutoff examples and unresolved timezone semantics prevent reliable deposit-date calculation. It does not establish API access, processor entitlement or account-specific funding timing. The private document is not committed.
- Current tenant documentation is [NAB IRIS API](https://nabankco.iriscrm.com/api). Its public [OpenAPI specification](https://nabankco.iriscrm.com/api/v1.yaml) declares version **1.42.0**, base `https://nabankco.iriscrm.com/api/v1`, and `X-API-KEY` authentication. Investigated specification SHA-256: `502128c9e400214c1357cc9bcedc88885900e018c7ddc97b8aec77db9a2c8271`.
- The older [official PHP SDK](https://github.com/iris-crm/php-sdk) describes an older monthly deposit path and 120 requests/minute. The current tenant docs advertise 500 requests/minute and add a required start day to the general deposits endpoint. The implementation follows the current tenant specification, not the old SDK examples.
- Both documented settings routes redirected this merchant user to merchant settings containing **User Settings only**. No API Settings tab or token was exposed. No token was created, no account permission was changed, and no browser cookie/session was extracted. Live API authentication is **not verified**.

## API contract used

Every outbound integration request is an HTTPS GET, with the token only in `X-API-KEY`. The origin must be an IRIS tenant subdomain; arbitrary URLs, paths, ports and redirects are rejected.

| Report | Path below `/api/v1` | Coverage |
| --- | --- | --- |
| Batches and nested transactions | `/merchants/{MID}/transactions` | Source batch/transaction IDs, date, type, signed amount, rejection flag, source invoice/purchase references when supplied. |
| General deposits | `/merchants/{MID}/deposits/{year}/{month}/{day}` | Deposit date, batch reference, amount, transaction count, and separate signed adjustments; `end_date` limits the window. |
| Chargeback cases | `/merchants/{MID}/chargebacks` | Optional: source case IDs, amounts/currency, status and response due date. |
| Retrieval cases | `/merchants/{MID}/retrievals` | Optional: source case IDs, amounts/currency, status and response due date. |
| Statements | `/merchants/{MID}/statements` | Optional: metadata only. No PDFs are automatically downloaded. The endpoint is not date-filtered; the window records the requested import context. |

Paginated reads use local page numbers with `per_page=100`. The client validates current/last page, stable total, complete row count and unique IDs; it never follows a server-provided pagination URL. Reads are bounded to 100 pages, 10,000 top-level rows, 4 MiB/response, 32 MiB/merchant and a 120-second request budget. Manual windows cover at most 90 dates. A rate-limit response stops the run with a sanitized message; the scheduler can retry on its next run.

The current specification also documents a flat reporting-transaction endpoint and TSYS-only ACH deposit/fee/reserve reports. Those are **not called** by this connector: processor entitlement and actual response samples are not established. General deposits must not be described as net ACH funding. Tips, currency and fees stay unknown when not supplied; there is no inferred USD or zero fee. Refunds retain their upstream type and signed source amount. No status normalization invents voids or unobserved refunds.

## REST API setup and operation

1. Sign into production Rupert at [rupert.stoverparc.org](https://rupert.stoverparc.org/). After this branch is deployed and migrated, open **POS & payment connections → NAB / IRIS merchant reporting** (`/pos_connections/iris_reporting`).
2. Obtain an approved API token from an IRIS user with access to the intended merchants and reporting. Official documentation states that tokens inherit the issuer's permissions. A token is not automatically read-only; use the narrowest available user/processor permissions. Creating a token or broadening permissions requires the owner's explicit action-time approval. A merchant portal password is not API authentication.
3. Choose Production, enter comma-separated merchant IDs (up to 10), confirm approved access, and save the IRIS origin and API token in Rupert's encrypted form. The origin has no `/api/v1` suffix. Blank secret fields retain saved values; fields are never filled with saved secrets. Saving performs no network request or import.
4. Run **Check read access**. It reads today's general deposits and batch/transaction reports for every configured merchant, without importing. A successful portal login alone is insufficient.
5. Run **Import IRIS reports** and inspect report status. Required deposit/transaction failure retains all previous snapshots. Optional 403/404 responses are marked unavailable and the run is partial; this does not mean there were no cases or statements. The statement schema omits collection pagination metadata: responses whose completeness cannot be established are also unavailable. Other malformed or failed responses abort the run.
6. Enable scheduled imports only after access is verified. `IrisReportingJob` is registered in Solid Queue for **06:45 America/New_York daily**, with a rolling 31-date window. The production jobs service/scheduler must be running. Opt-in and approved encrypted credentials are required; the browser session is never needed by the worker. This is ongoing operation while the service, permissions and vendor API remain available, not a guarantee that third-party access can never expire.
7. Review the latest status and report windows after deployment, key changes and vendor changes. Remove saved credentials to stop scheduled imports; historical reports remain for reconciliation. Preserve Rails encryption keys in private backups.

There is no webhook registration, account setting mutation, payment operation or stock write. Reports are tenant-scoped, encrypted source snapshots, with identity `(tenant, IRIS origin, MID, report kind, requested window)`. Replaying the same window updates it. Different windows can overlap and must **not** be added together. The UI shows the newest 30 snapshots and distinguishes unavailable reports. Snapshot amounts are not automatically posted to sales, the ledger, or a bank account. Card numbers, last-four digits, authorization codes and customer fields are excluded by an allowlist before persistence.

## Automatic native Daily Deposits website pulls

Choose **NAB website login · native Daily Deposits CSV** as the reporting access method on the IRIS connection page. Save the NAB username/password in the encrypted credential fields, explicit comma-separated merchant IDs and the authorization for read-only website exports. This uses the NAB tenant website, not its REST API; an approved REST token is not required. Switching methods clears previous credentials. Blank credential fields retain existing saved values, and secrets are never filled back into the form.

**Check read access** signs in and validates the current month's native CSV without saving reports. **Pull Daily Deposits now** reads the current and previous calendar months for every configured merchant. Enable daily imports for **06:45 America/New_York**. The production Solid Queue scheduler dispatches `IrisDailyDepositsWebJob`; each connection gets its own queued job with only the connection ID, not passwords or merchant data. The dashboard bank card exposes the status, last successful read and manual pull.

Each pull makes its own short-lived HTTPS login session. It reads the merchant identity and selected Daily Deposits table, requests the website's CSV export and downloads only the returned HTTPS file under the NAB tenant's official CDN temporary-export prefix. Login cookies and CSRF headers are never sent to the CDN. No existing browser cookies, hidden browser tokens, sessions or password-manager values are extracted. No payment, merchant setting, reserve operation or account permission is changed.

CSV counts/totals and every row must match the website table response before publication. All configured merchant/month reads finish before database writes; the snapshots and final success status commit together. A partial or malformed pull retains previous snapshots. Replays replace the same merchant/month snapshot and do not create sales. Currency and source type meaning remain unknown. The previous-month refresh captures some late corrections; older months need a deliberate manual backfill, not an unlimited refresh claim.

A wrong password, expired login or additional sign-in verification marks **Needs login** and pauses the opt-in schedule. Network/format errors mark **Error** and retain the prior reports; a later daily run can retry. Restoring authorized access requires a new successful check/pull and opting back in. Concurrent setup changes cannot publish an old result. A running pull is claimed once, with a ten-minute stale-run recovery limit and a 120-second network budget.

This website contract is not a vendor-supported API. It was derived from public frontend assets and verified with fresh independent sign-ins and native downloads for the intended accounts. Website changes may require a repair. REST access, native Health Center CSV and XLS remain separate unverified capabilities. See [automatic-import deployment evidence](iris-automatic-deposits-deployment-2026-10-15.md).

## CSV operation without an API token

The monthly summary form is available even when API access is missing. The operator identifies the MID from the source report. CSV imports require settings-write permission, stay in the current tenant, and never contact IRIS.

Use [Sales Health template](../data/iris-sales-health-template.csv) or [Transaction Health template](../data/iris-transaction-health-template.csv). These are **synthetic templates**, not downloaded merchant exports. Headers are `period,metric,value`; period is `YYYY-MM`. Supply all metrics for each month. Count metrics must be nonnegative integers. Sales gross minus returns must match net to one cent. Monetary values preserve their sign and have at most two decimal places; missing values are rejected instead of becoming zero.

English table matrices use month names across columns and the observed portal metric labels down rows. Specify the year of the final month; December/January boundaries are handled relative to that year. The `Total` column and year-over-year percentages are excluded from imported observations. Unsupported layouts, partial metrics, duplicate periods/metrics, fractional counts and files over 1 MiB fail before any write. Original file bytes are retained encrypted in the daily reconciliation document vault; the SHA-256 digest supplies replay provenance. Earlier imports cannot recover missing originals. Reimports replace the same monthly summary snapshot. The financial payload is encrypted.

## Native Daily Deposits CSV

Deployed to SER8; see [release, verification and recovery evidence](iris-native-deposits-deployment-2026-10-15.md).

Open **Import a native Daily Deposits CSV** on the IRIS connection page. In NAB, choose Deposits → Daily Deposits → Export → CSV. Supply the merchant selected in NAB, the source report month (`YYYY-MM`, 2000–2099) and the original CSV. API credentials are not needed. Settings-write permission and an active workspace are required.

The importer accepts the inspected native structure: `Daily Deposits` title, `Records exported: N` preamble, the exact `Date,Amount,Transactions,Batch,Terminal Number,Type` header, data rows, and a `Monthly Total` row with four to six cells and only empty padding after the amount/count. UTF-8 BOM and CRLF are supported. Dates are explicitly month/day/year and must fall in the selected month. Amounts are signed decimals with at most two fractional digits; valid dollar/grouping and parenthesized negatives are accepted. Counts are nonnegative integers. The exported record count and total amount/transaction count must match exactly. Missing batch/type, duplicate records, oversized cells, control characters, changed layouts, more than 10,000 rows or 1 MiB fail before persistence. Blank terminal numbers remain unknown; reference strings retain leading zeros.

One encrypted `daily_deposits_csv` snapshot is stored per tenant, origin, merchant and source month, with the file SHA-256. Reuploading replaces that same snapshot, including corrections or a later current-month export; uploading older files later can also replace it, so choose the intended source file. Report status describes successful validation of exported rows, not a closed or complete calendar month. The payload explicitly marks `export_records_only`, keeps currency unknown and preserves the source type string without interpreting it. Original CSV bytes are retained encrypted in the daily reconciliation document vault, preserving earlier files on corrections. No sales, inventory or ledger entries are created. Never sum overlapping snapshots or infer net bank funding from these batch amounts.

Synthetic [native shape fixture](../data/iris-daily-deposits-shape.csv) is accepted for tests. The real downloaded file was also validated privately inside a rolled-back test transaction; this does not establish every merchant/period layout. Native Health Center CSV and XLS compatibility remain unverified.

## NAB access request (prepared, not sent)

Ask your NAB representative or the tenant administrator to enable IRIS merchant-reporting API access for an approved integration user assigned only to your intended merchants. Request permission for GET batch/transaction reports, general deposits, chargeback/retrieval cases and statement metadata. Ask whether the processor supports the TSYS ACH reporting endpoints and whether a stable supported export delivery method is available. Supply account identifiers privately to NAB, not in public issues or code. Do not rotate payment gateway credentials to obtain reporting access.

## Verification and recovery

Tests use synthetic responses and cover encrypted/replay-safe storage, tenant and MID separation, denied optional access, atomic failure, stale setup, bounded/complete pagination, unsafe URL/redirect rejection, source-field filtering, scheduler opt-in, permissions and CSV validation. Local test results and CI must be recorded with the source commit; synthetic tests do not establish real merchant API access.

For deployment: preserve the active SER8 release and encryption configuration, take the established private database backup/snapshot, apply the single additive `CreateIrisReports` migration in rehearsal, deploy the reviewed branch/release, restart web/jobs through the established deployment workflow, and verify health plus the authenticated setup page. No production switch is performed merely by pushing the branch. Inactive integration credentials do not prevent ordinary Rupert operation.

For daily controls, retained originals, review notes and nightly archives, see [Daily reconciliation and document retention](daily-reconciliation-retention.md).
