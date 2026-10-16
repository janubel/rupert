> Historical investigation retained during repository reconciliation. Later deployment and access findings supersede its operational status. [Original revision](https://github.com/techmore/rupert/blob/e2b5e81c5b3c3c49adb07a3ca115317e23b5ab83/docs/ops/authorize-net-integration-investigation.md).

# Authorize.net integration investigation

Reviewed 2026-10-15 for Rupert. This is a bounded investigation of gateway reporting, merchant access, Shopify dependencies, reconciliation completeness and the implemented connector. It is not a certification of this merchant's live API access. Credentials, merchant identifiers, customer records, private exports and deployment/access details are intentionally excluded.

## Decision and evidence

Use Authorize.net as a payment-observation source. Keep Shopify orders and C-Trax retail inventory as separate sources of truth. Importing a gateway payment must not create another sale or stock movement. The existing reporting connector is suitable for a controlled first read once approved credentials are available; it is not yet evidence of a complete bank reconciliation.

| Question | Finding | Evidence level |
| --- | --- | --- |
| Can the API report existing payments? | Yes: merchant details, batches, settled/unsettled lists and transaction details have official contracts. | Official documentation/schema; synthetic tests. |
| Is there a vendor-enforced read-only credential? | OAuth `read`; partner application registration and merchant consent are prerequisites. | Official OAuth documentation; live entitlement unverified. |
| Is a Transaction Key read-only? | No. It is a shared merchant payment credential. The connector restricts its own methods. | Official credential documentation; implementation inspection. |
| Could generating a key break Shopify? | Yes, if Shopify uses the replaced merchant key. The store-specific account linkage is still unverified. | Official Shopify integration guide; no authenticated Shopify inspection. |
| Does portal access prove API permission? | No. Reports were visible; user role and Transaction Details API entitlement were not independently verified. | Earlier read-only portal inspection. |
| Has live authentication/import succeeded? | No. No reporting credentials have been supplied or saved for this integration. | Deployment verification; no live reporting API call. |
| Are tips available? | Optional detail field exists; actual processor/account population is unknown. | Current XSD/reference; portal sample was inconclusive. |
| Are fees available anywhere? | Gateway billing statements and processor statements can contain fees. This connector has no verified fee or net-payout API contract. | Official billing support documentation; no private statement inspected. |
| Are all voids/declines guaranteed? | No. Daily list polling cannot discover every event that disappeared before its first observation. | Connector discovery-path analysis. |

The earlier portal session showed settlement/transaction details, key-management metadata and no authorized OAuth applications. An empty Authorized Applications list does **not** rule out Shopify or another integration using API Login ID + Transaction Key. The session expired; the owner elected to continue without portal access. No key, merchant setting or payment was changed.

## Credential choices and permissions

| Access path | What it grants / requires | Rupert support and decision |
| --- | --- | --- |
| Existing API Login ID + Transaction Key | Merchant gateway authentication, including payment-processing capability. Portal login permissions do not turn this key into a reporting-only credential. | Supported explicit fallback; reuse the existing key securely. Never generate one just to set up reporting. |
| OAuth `read` | A registered partner application and owner/administrator merchant consent. | Supports an already issued refresh token, client ID and secret. Rejects token responses whose granted scope is anything other than exactly `read`. |
| Portal reporting user | Interactive access governed by that user's role. | Useful for independent reports/exports; not API authentication and never stored in Rupert. |
| Public Client Key | Client-side Accept tokenization. | Does not authenticate reporting. |
| Signature Key | Integrity verification for webhook notifications and other signing use cases. | Does not replace reporting authentication. No key generation or webhook registration is implemented. |
| Shopify app client credentials | Access for Rupert's Shopify catalog/order integration. | Separate from the Authorize.net payment app's merchant gateway credential. Do not interchange them. |

[Partner registration and OAuth flow](https://developer.authorize.net/api/reference/features/oauth.html) require initial consent and authorization-code exchange. Rupert implements refresh only, not that onboarding flow. New Experience [partner setup](https://support.authorize.net/knowledgebase/article/KA-07525/) and [merchant authorization guidance](https://support.authorize.net/knowledgebase/article/KA-07620/en-us) describe the corresponding interfaces. Merchant access alone does not establish partner entitlement. The official OAuth pages disagree about token lifetimes; do not promise an exact revocation deadline from those conflicting descriptions. Rupert refreshes once per operation and fails closed on scope/authentication failure.

The [Transaction Details API help](https://account.authorize.net/helpCP/Account/Settings/Security_Settings/transaction_details_api.htm) describes a separate account feature. Its enabled state remains unknown here. `vendor_approved` in Rupert is an operator declaration, not proof returned by Authorize.net. A successful credential-only `authenticateTestRequest` in the existing Valmar checker also does not prove reporting access.

## Shopify continuity and matching

The [Authorize.net Shopify payment-app guide](https://www.authorize.net/support/shopify-platform-update.html) uses merchant API Login ID + Transaction Key. The [credential guide](https://support.authorize.net/knowledgebase/article/000001271/en-us) allows reuse across sites and says a replacement invalidates the old key immediately when selected or automatically after 24 hours. The overlap delays disruption; it does not create a permanent second reporting key. All consumers must be inventoried and updated together before any future rotation. Reporting setup itself requires no rotation, Shopify reconnection, test-mode change or test purchase.

To resolve the actual dependency later, inspect Shopify Settings → Payments read-only, identify the active payment app, and verify its merchant-account mapping with the owner or current credential keeper. Masked fields may prevent definitive comparison. Do not infer the account from matching dates, amounts, generic card tenders, a missing OAuth application, or the mere presence of an API Login ID.

Rupert's `CanonicalOrderImporter.shopify_payments` currently reduces `paymentGatewayNames` to `gift_card`, `cash` or `card` and uses an order-total-derived tender. This loses gateway identity and itemized transaction provenance. The existing mirror cannot prove which gateway currently processes checkout, and its tender total is not an independently verified gateway capture total.

The Shopify payment app uses Shopify Payment IDs distinct from Authorize.net `transId`; its guide describes the Payment ID appearing in the gateway description. Rupert deliberately discards free-text descriptions, so automatic Shopify matching is not implemented. Shopify's [2026-07 OrderTransaction contract](https://shopify.dev/docs/api/admin-graphql/2026-07/objects/OrderTransaction), matching Rupert's configured API version, exposes typed `paymentId`, `gateway`, `kind`, `status`, `parentTransaction` and amounts. Its `receiptJson` is explicitly unstable and should not drive matching logic. Its `fees` field is limited to Shopify Payments; it is not a substitute for Authorize.net processor fees.

A future matcher should preserve typed Shopify transaction IDs and parent relationships, verify the bridge with representative existing transactions, and leave ambiguous matches unresolved. Amount/date similarity is supporting evidence only. Never convert a guessed match into another sale or merge identifiers from different namespaces.

## Reporting contract and implementation

Rupert sends JSON by HTTPS POST to fixed `/xml/v1/request.api` endpoints: `api.authorize.net` for production and `apitest.authorize.net` for sandbox. POST is the transport; the allowlisted request determines whether the operation reads or processes a payment. These environments use separate credentials and provenance.

| Request allowed by this connector | Purpose | Implementation boundary |
| --- | --- | --- |
| `getMerchantDetailsRequest` | Verify Gateway ID; inspect enabled currencies. | Configured numeric Gateway ID must match. Returned contacts/other merchant data are not persisted. |
| `getSettledBatchListRequest` | Discover settled batches in a bounded UTC window, with statistics. | Ordered window at most 31 days; no merchant cut-off/time-zone changes. |
| `getTransactionListRequest` | Discover payments in each batch. | Page size 1,000; page-number offsets; first-page total and duplicate/incomplete-page validation. |
| `getUnsettledTransactionListRequest` | Discover current pending payments. | Same pagination checks; not a historical all-events search. |
| `getTransactionDetailsRequest` | Retrieve current details for discovered or previously pending IDs. | Response ID must match the requested ID. |

The [current API reference](https://developer.authorize.net/api/reference/index.html#transaction-reporting) documents paging beyond 1,000 records; the abbreviated overview's 1,000 wording is not a total-history guarantee. Offsets are page numbers. The batch-date contract uses an inclusive range, treats a midnight end specially, and limits earliest start to January 1 two years before the current year. For a 2026 investigation that boundary is 2024-01-01; account availability still needs verification. Rupert uses explicit UTC timestamps and 23:59:59Z for an entered end date. Do not use deprecated SOAP PDFs as the implementation contract.

The live [XSD](https://api.authorize.net/xml/v1/schema/AnetApiSchema.xsd) was fetched again during this audit and matched the originally reviewed file. SHA-256: `c9c76cdbeba1f030bb453cdeec963457b9f85c6799db9b3888b0ade1a635a1fa`. Schema presence establishes field shape, not processor population or merchant permission.

## Financial data and limits

| Subject | Stored / reported | What remains unresolved or excluded |
| --- | --- | --- |
| Payment amounts | Exact decimal authorization and settlement amounts; source type and status. | Authorization is not captured revenue. No complete accounting ledger is created. |
| Refunds | Separate gateway ID, positive source amount and original `refTransId` when supplied. | Original may be outside the imported window. Refund and sale must not be counted as two sales. |
| Voids | Current source status; previously observed pending IDs are revisited. | No guaranteed void execution timestamp or discovery of never-observed historical voids. |
| Batches | Gateway/batch ID, settlement UTC time/state, payment method and allowlisted statistics. | Batch settlement does not establish the date/amount of bank funding. |
| Tips | Optional `tip.amount`; missing remains NULL/Unknown. | No verified account coverage, attribution to employees, or tip liability accounting. A returned tip is already part of the payment total and must not be added again. |
| Customer surcharge | Optional `surcharge.amount`; missing remains unknown. | Not a merchant processing fee. Reference describes processor-specific support, including TSYS. |
| Fees | No per-transaction fee value imported. | Gateway billing fees, processor fees and Shopify platform fees are distinct sources. Do not estimate them from a headline rate or authorization/settlement differences. |
| Currency | Merchant currency assigned only when exactly one is enabled; otherwise unknown. | This is a present merchant-configuration inference, not a per-transaction currency guarantee or historical FX proof. Unknown currency is excluded from monetary totals. |
| Disputes / ACH returns | Available batch aggregate counters/amounts are retained. | No complete per-case dispute/return ledger, reason/timeline or subsequent funding adjustment import. |
| Tax / items / shipping | Not imported from gateway detail. | No item-level inventory or tax reconciliation. C-Trax remains the retail inventory reference. |
| Histories | Latest observation plus observed status changes. | Amount changes and every intermediate gateway event are not recorded as a financial event history. |

[Authorize.net billing guidance](https://support.authorize.net/knowledgebase/article/KA-07323/en-us) describes gateway billing statements and monthly PDF downloads in the new interface, including up to 24 months of statements. Merchant account statements come from the MSP. Availability for this account has not been checked. Its [chargeback guidance](https://support.authorize.net/knowledgebase/article/000001216/) routes credit-card chargeback records to the MSP and distinguishes eCheck reports. A fee/deposit phase therefore needs actual gateway billing, processor settlement/fee and bank statement contracts; none is silently inferred from this connector.

## Completeness, scheduling and recovery

The opt-in job runs at 06:20 America/New_York. Each import revisits seven days of settlements, the current unsettled list and all stored nonfinal transaction IDs for this merchant/environment. Manual backfills use at most 31-day windows. Settlement-day totals use UTC, while status counts use the submission day. Portal local-time or processor business-day totals can legitimately differ unless boundaries are aligned. The merchant's actual cut-off time was not verified or changed; [vendor batching guidance](https://support.authorize.net/knowledgebase/article/000001244/) distinguishes automatic batching from processor settlement.

Polling is an observation model. A payment submitted and voided between polls may never enter the discovered set. A settled payment outside the seven-day overlap is not automatically refreshed just because it changes later. Outages longer than the overlap require explicit backfill. A first import is not an all-history import. Source list changes can trigger an incomplete-page error; retry with an appropriate smaller window rather than accepting partial results.

One transaction-detail call is made per unique discovered/revisited ID. Limits are 100 pages per list, 20,000 unique detail IDs per import and 8 MiB per response. Calls are sequential, with per-request timeouts and no automatic network retries. There is no measured account throughput, vendor rate-limit entitlement, total import deadline, durable per-page checkpoint or automatic multi-window catch-up. Large imports can occupy the default queue alongside other jobs; use conservative backfills until actual volume/runtime are measured.

[Webhooks](https://developer.authorize.net/api/reference/features/webhooks.html) can reduce discovery latency for refund/void and other events, but complement reporting rather than replace it. They need merchant enrollment, a Signature Key, signature verification, durable notification deduplication, prompt acknowledgement and later detail reads. Vendor retries are finite and failed delivery can deactivate a webhook. Rupert has no Authorize.net webhook receiver; adding one would be a separately authorized merchant-setting change and cannot recover past events never delivered. No webhook was created or tested.

[New-interface settlement exports](https://support.authorize.net/knowledgebase/Knowledgearticle/?code=KA-05369) provide a manual comparison source, with tab-delimited, expanded CSV and Excel options. These exports may contain customer/card-related fields. A portal CSV importer, export scheduler and statement parser are not implemented. Keep real files private; a future importer needs a reviewed native schema, allowlisted fields, source identity, replay protection and reconciliation tests before use.

## Security, provenance and failure behavior

The reporting client never delegates to `AuthorizeNetClient`, whose checkout behavior can charge. Its five-request allowlist rejects other methods and authentication overrides. Fixed vendor destinations, certificate verification, disabled proxy discovery, rejected redirects, bounded responses and sanitized errors reduce secret-disclosure paths. No credentials or raw provider responses are deliberately logged or persisted as observations.

Secrets are encrypted in `PosConnection.credentials_json` using Rupert's existing encryption mechanism; form values stay blank, request credential containers are filtered, and connection responses prohibit caching. TLS protects transport. Encryption keys and private backups remain operational secrets. Authorized server code can decrypt credentials; encryption at rest does not restrict a payment-capable key to reporting.

Tenant-scoped models and unique indexes isolate source IDs by tenant + environment + Gateway ID. Setup versions reject stale queued work and stale writes. A source ID replay updates the existing observation. Data fetch/normalization precedes an atomic local transaction, so a failed import does not leave a partial set of observations. OAuth refresh-token rotation is a separate encrypted save and may succeed even when the following import fails. Disconnect removes credentials/disables scheduling but retains imported history. Changing account/environment filters the view to the new provenance scope rather than relabeling old rows.

Settings-read access can view reports; setup, diagnostic requests and imports require settings-write access and an active workspace/user. Saving configuration has no implicit network or import side effect. Manual import and enabling the schedule do not mechanically require a previous successful diagnostic; operators must perform the acceptance sequence below. The daily job still requires explicit enablement, approved-access declaration and saved credentials.

## Acceptance plan and open work

| Priority | Smallest next action | Completion evidence |
| --- | --- | --- |
| Activation | Obtain the existing merchant credential securely, or complete approved OAuth `read` onboarding. Enter secrets directly in the intended Rupert workspace. | Encrypted saved connection; no key rotation or secrets in GitHub/chat. |
| Reporting entitlement | Run Check read access. If denied, inspect the existing Transaction Details API feature/role with the owner; do not auto-enable it. | Matching Gateway ID and successful reporting probes. Empty accounts leave list/detail probes explicitly unverified. |
| First import | Import a small historical UTC window using existing transactions only. | Source IDs, statuses, batches and currency compared privately with independent portal results. No test charge/refund/void required. |
| Replay / daily operation | Repeat the window, inspect counts/history, then enable daily reporting. | No duplicate source rows; successful recurring run with observable status. |
| Completeness | Compare charges/refunds separately and review void/decline discrepancies over several business days and date boundaries. | Explained differences; documented coverage limits, backfill procedure and queue runtime. |
| Shopify linkage | Inspect active provider/account, then review typed transaction provenance and a verified matching bridge. | Explicit account relationship and sample-backed matches; ambiguous records remain unresolved. |
| Fees / deposits | Obtain native gateway billing, MSP and bank statement specifications privately. | Separate verified source contracts and totals; no guessed processing-fee allocation. |
| Later hardening | Consider import-wide time budgets, separate queue/checkpoints, stale-import alerts and a coverage/completeness indicator. | Changes justified by measured volume and operational requirements. |

Still unknown: exact account role, enabled reporting feature, partner registration access, live OAuth/read entitlement, active Shopify provider/account mapping, tip/surcharge population, live volume/limits, actual merchant cut-off/time zone, processor fee/funding exports and completeness of historical nonsettled events. These cannot be resolved by additional fixture tests or by generating a replacement key.

## Implementation evidence and validation

Audited files: `web/app/services/authorize_net_reporting/{client,check,import}.rb`, `web/app/jobs/authorize_net_reporting_job.rb`, `web/app/models/pos_connection.rb`, reporting models, `web/app/controllers/pos_connections_controller.rb`, the reporting partial, encryption/logging configuration, migrations/schema indexes and recurring schedule. Shopify mirror behavior was traced through `web/app/services/canonical_order_importer.rb` and the API version through `web/app/services/shopify_client.rb`.

Synthetic coverage is in `web/test/services/authorize_net_reporting_test.rb` and `web/test/integration/authorize_net_reporting_test.rb`: replay/provenance, refund/void states, decimal/optional-field handling, pagination, incomplete/malformed responses, atomic failure, tenant/environment/merchant isolation, concurrent setup changes, encrypted OAuth renewal/read scope, diagnostics, queued work, permissions and display-limit-independent totals. These are software/contract checks, not proof of real merchant API availability.

Original source draft [#43](https://github.com/techmore/rupert/pull/43), combined C-Trax draft [#45](https://github.com/techmore/rupert/pull/45), and current-release guidance draft [#50](https://github.com/techmore/rupert/pull/50) passed both PostgreSQL and SQLite CI before this research extension. Prior combined local validation was 869 tests / 6,292 assertions; repository lint passed. No merchant data, live credentials or copied browser sessions are included in these artifacts. See the [operator runbook](authorize-net-reporting.md) for setup and supported reporting behavior.

Research-extension validation: 53 targeted reporting/connection tests / 474 assertions passed, with zero failures/errors. Repository-configured lint for the changed integration test, generated product-site consistency, all 19 documentation-page local links, Markdown local links, credential-assignment review and whitespace checks passed. No new vendor API calls using merchant credentials were made.
