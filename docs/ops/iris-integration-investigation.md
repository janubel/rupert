# NAB / IRIS integration investigation

Investigated October 15, 2026, America/New_York. This records the available integration routes, evidence, implementation gaps and steps needed to enable unattended reporting. Read alongside the [operating runbook](iris-reporting.md) and [deployment record](iris-deployment-2026-10-15.md).

## Finding and recommendation

The supported tenant REST API remains the preferred vendor contract for broad unattended reporting. A subsequent implementation also verified a fresh-login website route for native Daily Deposits, documented in the operating runbook. Rupert already implements encrypted, tenant-scoped report snapshots and an opt-in daily worker. Account access is still the gate: the authenticated merchant user exposes User Settings only, with no API Settings tab or approved API token. Public API documentation proves a contract exists; it does not prove that this account is entitled to use it.

A **native Daily Deposits CSV was successfully downloaded and inspected** during this extended investigation. Its preamble, columns, record count and aggregate totals were validated privately. This is a different report from Health Center monthly summaries, and it is now supported by a separate native Daily Deposits importer with explicit merchant/month context. The monthly-summary parser remains separate. Native Sales Health and Transaction Health bytes remain unverified. The six previously imported monthly snapshots remain explicitly visible-table transcriptions.

The TSYS funding reference PDF also downloaded successfully. It provides operational context, not credentials, a merchant-specific funding agreement or evidence of TSYS API entitlement. No API token, webhook, account setting or payment operation was created.

## Evidence and confidence

| Evidence | What it establishes | What it does not establish |
| --- | --- | --- |
| Authenticated merchant portal | Two selectable merchant accounts; deposit/batch/case/statement sections; Health Center CSV/XLS menus. | Backend API access, processor-specific endpoint permission or scheduled file delivery. |
| Native Daily Deposits CSV | Actual downloadable CSV structure and agreement between its data rows, advertised record count and total amount/count. | Health Center layout, refund/adjustment behavior across other periods, net ACH funding or importer compatibility. |
| Documents PDF | Funding reference is readable and downloadable through the merchant UI. | API provisioning or binding deposit timing for either merchant. |
| Current tenant OpenAPI | Version 1.42.0; endpoint paths, methods, parameters and declared response shapes. | Successful authenticated requests, completeness of processor feeds, retention or runtime conformity. |
| Rupert source and prior tests | Bounded GET-only API client, encrypted snapshots, manual summary CSV import and scheduler implementation. | Live API success or support for unimplemented reports. |

Private exports, document bytes, merchant identifiers and provenance remain outside public Git with mode `0600`. Only generic structure and synthetic examples are included here. Profile navigation did not produce a usable processor detail view during this pass; Statements selection did not establish a downloadable statement. Neither is counted as verified content.

## Integration routes

| Route | Suitability | Current status / next gate |
| --- | --- | --- |
| Tenant REST reporting | Preferred for independent daily imports, pagination and source IDs. | Implemented subset; approved reporting user/token and real response validation required. |
| Native Daily Deposits CSV | Batch-summary reconciliation without REST API access. | Native parser and independent website login/download worker implemented; explicit merchant identity, row/count/total verification; see the operating runbook. |
| Health Center monthly CSV | Monthly sales/returns/case summaries. | Menus and visible matrices verified; native download bytes not delivered. Existing importer accepts documented synthetic template and observed matrix only. |
| XLS | Possible manual source if vendor supplies a workbook. | Menu visible; workbook bytes, sheets, date types and formulas unverified; no parser. |
| Statements | Potential independent source for monthly fees, adjustments and reconciliation. | REST list/download documented; no real statement inspected or fee parser implemented. |
| Subscriptions/webhooks | Possible timely chargeback/retrieval status notifications. | Events published; no receiver/registration; authentication and delivery guarantees unresolved. |
| Scheduled email, SFTP or vendor file feed | Could remove interactive export dependency. | No supported report-file delivery contract verified. Deposit email alerts do not establish attached CSV delivery. |
| Website GraphQL | Interactive website export machinery, distinct from the REST API. | Daily Deposits flow now verified using a new server login and downloaded native CSV; Health Center automation remains unverified. Not a vendor-supported integration contract. |
| NMI Gateway / NMI Payments APIs | Conditional alternatives for separately provisioned accounts. | Distinct credentials/products; an IRIS merchant login does not prove eligibility. |

The publicly served [Health Insights UI bundle](https://cdn.iriscrm.com/assets/main/7e65daba/build/assets/HealthInsightsPage-DY9R5sA-.js) contains `healthInsightExportMonthlySales` and `healthInsightExportTransactionHealth` operations whose results include `export_url`. This explains an interactive export path, not an approved backend API. Daily Deposits and PDF downloads succeeded while both Health Center CSV attempts still delivered no file; the exact Health Center failure is unresolved.

NMI now calls IRIS CRM **Merchant Central**; its [official product page](https://www.nmi.com/products/merchant-central/) describes portfolio reporting and processor integrations. That branding does not make all NMI credentials interchangeable. The [Gateway Classic Query API](https://docs.nmi.com/reference/query) uses its own authentication, while the [NMI Payments Deposit History component](https://docs.nmi.com/docs/deposit-reporting-component) requires an active NMI Payments account. Those are conditional projects after account eligibility is established, not substitutes for a missing IRIS token.

## REST contract and endpoint coverage

Authoritative references: [tenant API documentation](https://nabankco.iriscrm.com/api), [OpenAPI YAML](https://nabankco.iriscrm.com/api/v1.yaml), and the derived [selected contract inventory](../data/iris-reporting-contract-1.42.0.json). The inventory contains paths, parameter types, selected schema shapes and the complete published subscription event enumeration; it contains no merchant responses. Specification SHA-256: `502128c9e400214c1357cc9bcedc88885900e018c7ddc97b8aec77db9a2c8271`.

Authentication is an `X-API-KEY` header against `https://<tenant>.iriscrm.com/api/v1`. Tokens inherit their issuing user's assigned merchant/lead/group/processor permissions. Rupert's HTTP client restricts its own operations to GET; this does not reduce the vendor token's permissions. Prefer a dedicated integration user with only the required merchants and reporting rights.

The current tenant documentation advertises 500 requests/minute and rate-limit headers `X-RateLimit-Limit`, `X-RateLimit-Remaining` and `Retry-After`. Endpoint-specific page sizes take precedence over the introduction's general list-size language. The [older official PHP SDK](https://github.com/iris-crm/php-sdk) has older deposit and rate-limit examples; use the current specification and actual responses.

Paths below are relative to `/api/v1`; `{MID}` replaces the specification's `merchantNumber` parameter.

| Endpoint family | Contract / use | Rupert coverage |
| --- | --- | --- |
| `GET /merchants`, `GET /merchants/{MID}` | Merchant discovery, processor/source context. Equipment and assigned-user reads are also published. | Not called. Configure explicit merchant IDs; do not ingest contact/profile data for reporting. |
| `GET /merchants/{MID}/transactions` | Paginated batches containing nested transaction records, source IDs and amounts. | Implemented required report. Complete batch pagination is checked; nested transactions must have unique numeric IDs within each batch. Live nested completeness remains a vendor question. |
| `GET /merchants/{MID}/deposits/{year}/{month}/{day}` | General deposits and separate adjustments with `end_date`. | Implemented required report. Stores rows rather than duplicating totals as sales. No claim of net ACH coverage. |
| `GET /merchants/{MID}/reporting/transactions` | Flat transactions; required start/end dates; type filters `payment`, `refund`, `other`; page sizes through 1,000. | Not implemented. Candidate for simpler transaction reconciliation after testing source IDs and corrections against batches. |
| `GET /merchants/{MID}/authorizations` and `/{batchId}/transactions` | Authorization batches and their paginated records. | Not implemented. Authorization is not evidence of settlement or a second sale. |
| `GET /merchants/{MID}/chargebacks`, `/retrievals` | Case lists, plus detail and attachment reads by case number. | Lists implemented as optional reports. Details/files not downloaded. Case-response POST operations are outside reporting scope. |
| `GET /merchants/{MID}/statements` and `/{statementId}` | Statement list and download. List schema has inconsistent placement of pagination metadata. | Metadata only; unavailable when complete collection pagination cannot be established. No PDF downloader/parser. `POST /statements/1099k` imports a document; it is not a read endpoint. |
| `GET /merchants/{MID}/reporting/deposits` | TSYS ACH records; status `completed`, `failed`, `released`; date filter capped at three months; page size at most 100. | Not implemented or entitled. Candidate source for actual funding rather than batch gross. |
| `GET /merchants/{MID}/reporting/deposits/{depositId}` | TSYS funding summary with fee/refund/reserve statistics. | Not implemented. Missing fees/reserves must remain unknown. |
| `GET /merchants/{MID}/reporting/deposits/{depositId}/transactions` | Paginated transactions contributing to a TSYS deposit. | Not implemented. Published row schema lacks a stable transaction ID; matching/deduplication requires clarification. |
| `POST` on those three TSYS deposit reporting paths | CSV generation/download operations in the current spec. | Not called by Rupert's GET-only client. Vendor documentation links sometimes suggest `/export`; the actual specification path/method is the contract to validate. |
| Portfolio, memos, residuals and reserve administration | Broader ISO/agent operations exist in the public API. | Outside this merchant-reporting connector. Residual splits are not merchant processing fees; reserve transfer/release operations must not be invoked for reconciliation. |

The TSYS deposit list declares a string reference ID, while detail paths declare an integer deposit ID. Do not infer that the visible reference string is an acceptable detail-path identifier. Confirm the mapping with NAB and a sanitized response before implementing drill-down.

## Native CSV and PDF findings

The native Daily Deposits download has this structure:

1. A one-cell report title, `Daily Deposits`.
2. A one-cell `Records exported: N` preamble, then a blank row.
3. Header: `Date,Amount,Transactions,Batch,Terminal Number,Type`.
4. Six-cell data records.
5. A shorter `Monthly Total` aggregate row.

The private sample's count and amount totals agree with its records, and its complete rows are unique. The observed type is a numeric-looking value whose business meaning is not documented; do not translate it into payment/refund/void status. The file does not carry sufficient verified merchant, currency or period metadata to safely infer those values. Explicit operator source context is needed. This is a batch/deposit summary, not a per-payment export. The generic example in [synthetic shape fixture](../data/iris-daily-deposits-shape.csv) is deliberately invented and accepted by the new native importer; it does not belong in the monthly-summary parser.

The native parser validates the title/header, declared count and totals, excludes aggregate rows from data, preserves batch and terminal references as strings, distinguishes missing values, retains signed decimal amounts and rejects dates outside the explicitly selected month. It uses its own snapshot kind, explicit MID/period context and digest provenance; source type strings remain uninterpreted. Do not turn its rows into sales or coerce it into a Health Center summary. Additional months, returns, adjustments, empty reports and each merchant must be examined privately before compatibility is claimed.

The portal's TSYS funding PDF describes morning and overnight ACH cycles and batch cutoffs. It also acknowledges receiving-bank availability. Its missed-morning-cutoff description conflicts with its next-day example, and it uses EST/PST labels without resolving daylight-saving behavior. The time-zone chart needs clarification before use in code. No funding SLA, holiday/calendar rule, processor assignment or automated deposit-date prediction can be derived reliably from this reference alone. Dejavoo quick-reference titles concern terminal operation/dual pricing; they are not an API specification or proof of tip/fee semantics.

## Webhook investigation

The published subscription schema requires a destination URL and event list and can bundle multiple items per request. It includes chargeback/retrieval added, updated and reminder events, residual events, merchant user assignment and gateway-boarding events, and `api.updated`. The current 41-event enumeration contains **no transaction, batch, deposit or statement event**. Webhooks therefore cannot replace scheduled financial polling on this contract.

The public subscription schema and examples do not establish a webhook signing secret, signature verification algorithm, delivery retry schedule, ordering guarantee or retention/replay contract. These remain vendor questions, not proof that all protections are absent. Before enabling any receiver, verify authenticity, replay handling, tenant/MID assignment, payload minimization, duplicate `hook.requestId` behavior, bounded queues and reconciliation polling. No subscription has been registered and Rupert has no IRIS receiver.

## Gaps before unattended production acceptance

The deployed code stores source observations, not an accounting ledger. Native Daily Deposits website automation subsequently adds independent login/export validation and a daily current/previous-month refresh; it does not establish REST entitlement or automate case/statement reports. Its rolling 31-date schedule does not establish coverage of older cases that change later. Different windows overlap and cannot be summed. Optional denial means unavailable, not zero activity. Missing currency/tips/fees remain unknown; UI dollar formatting is not an API currency contract.

The client stops on 429 and retains prior snapshots; it does not currently schedule a precise `Retry-After` retry. Error state is stored on the connection; no dedicated IRIS alert, freshness dashboard or snapshot retention policy has been implemented. Each new rolling window creates another snapshot identity, so storage growth needs an explicit retention decision. These are operational improvements after access is proven. Batch pagination checks do not independently prove that each nested transaction array is complete. Raw source date/status semantics also need real processor validation. If the vendor migrates the tenant away from `iriscrm.com`, review the supported origin contract before changing Rupert's allowlist.

Acceptance should establish:

- **Access and feed scope:** an approved user/token; intended merchant separation; supported processors/endpoints; read permissions; history retention; vendor feed delay; timezone and currency; safe token rotation/revocation. No copied browser session credentials.
- **Response conformity:** empty and populated periods; 100/101-row boundaries and multiple pages; stable totals and IDs; truncated/malformed responses; permission denial versus no records; statement collection pagination; nested batch completeness; numeric/string amount and ID variations.
- **Financial meaning:** purchase/refund/void/reversal/reject behavior; signed amounts; late corrections and case updates; gross versus net settlement; reserves, fees and adjustments; TSYS reference/detail ID mapping; reconciliation to a private bank/statement source. Do not match solely by amount/date or double-count authorizations.
- **Replay and recovery:** same-window replay, overlapping windows, interrupted reads, concurrent setup changes, stale credentials, 429 handling, missed schedules, catch-up windows, encrypted backup/restore and a visible freshness/failure signal. Decide a bounded older-case refresh/backfill policy.
- **Files:** real native Health CSV/XLS bytes before parser claims; separate Daily Deposits parser tests; every merchant and representative edge periods; statement parsing only after source inspection and review. Keep all real samples private and use synthetic test fixtures.

Existing synthetic automated tests cover the implemented storage/client/import/scheduler and summary CSV boundaries; see the deployment record for the tested revision. The subsequent native Daily Deposits importer adds runtime support for the inspected file format and was tested privately against the real download in a rolled-back transaction. It does not prove any of the outstanding live API tests.

## Precise vendor questions (prepared, not sent)

Ask the NAB tenant administrator to provide the supported path to a reporting integration user and approved token assigned only to the intended merchants. Confirm whether API Settings is intentionally unavailable to merchant-role users and whether access requires enablement, a different user role or a commercial agreement.

Request endpoint-level permission and processor coverage for batch transactions, general deposits, flat transactions, authorizations, chargebacks/retrievals, statements and TSYS ACH reports. Ask for sanitized examples, pagination guarantees, nested completeness, source ID semantics, timezone/currency, status corrections, history limits and ingestion lag. Clarify the TSYS list/detail ID mismatch and statement list pagination.

Ask whether supported native CSV/XLS delivery can run without a browser, and whether scheduled attachments or SFTP exist for this tenant. Request Health Center layout/version details, numeric Daily Deposits type definitions, workbook formats, webhook signature/retry/replay documentation and corrected funding-time guidance. Account identifiers belong only in a private NAB support channel. No support email or ticket was sent by this investigation.

After access is provided, use Rupert's existing encrypted setup, run the read-access check, validate bounded manual imports and only then opt into daily reporting. A GitHub push does not activate API access or deploy runtime changes.
