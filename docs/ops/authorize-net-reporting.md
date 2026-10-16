# Authorize.net read-only reconciliation

Investigated 2026-10-15. This draft implements gateway reporting in Rupert. Authenticated portal reporting was inspected: settlement reports and transaction detail screens were accessible. This establishes portal visibility only. Live reporting API access remains **unverified** because the existing Transaction Key has not been supplied. No live reporting API calls, merchant setting changes or payment operations were performed. API Login IDs, merchant identifiers, private transaction samples and credentials are excluded from this public guide. C-Trax remains the retail inventory reference.

## Access and credentials

The new **POS & payments → Authorize.net reporting** connection is separate from the existing Valmar credential check and the existing `AuthorizeNetClient` checkout adapter. Reporting never calls that payment adapter and never copies secrets into checkout settings.

| Method | Credential capability | Setup in Rupert |
| --- | --- | --- |
| OAuth `read` | Vendor-enforced reporting access | Existing approved OAuth application client ID/secret and merchant refresh token; refresh responses must grant exactly `read`. |
| API Login ID + Transaction Key | Merchant gateway credentials can also process payments | Explicit fallback using the existing key only when authorized for this integration. This connector restricts its own API methods; the key itself is not read-only. |
| Merchant portal username/password | Interactive portal login; user permissions apply there | Never stored or used as API reporting credentials. |
| Public Client Key / Signature Key | Accept tokenization / webhook integrity | Not reporting authentication. |

The official OAuth guide requires registration in the **Partner Interface**, followed by merchant owner/admin consent. This PR supports refreshing an already issued token; it does not implement application registration, initial consent/code exchange or imply that Herbal Healers has partner access. Do not generate or rotate live Transaction/Signature Keys: that can disrupt existing checkout integrations.

All integration secrets use `PosConnection.credentials_json` and Rupert's existing Rails encryption keys. Forms remain blank, request parameter containers are filtered and responses prohibit caching. OAuth access tokens live only in memory; refreshed refresh tokens are saved encrypted with a setup-version check. Preserve production encryption keys when backing up.

## Operator workflow

1. Sign into the official [Merchant Interface](https://account.authorize.net/). Inspect user role, reporting access, Gateway ID and existing authorized applications without changing settings. Where the interface exposes Transaction Details API availability, inspect whether it is already enabled; do not change it automatically. Partner access is a separate login/entitlement.
2. In Rupert, select environment, enter the numeric **Gateway ID** as the merchant reference, choose authentication method and save to reveal its credential fields. Confirm approved integration access and enter credentials directly in the encrypted form. Blank fields retain saved values. Environment/method changes clear old credentials.
3. **Check read access** verifies merchant identity, recent settled batches and the unsettled transaction list. It probes a settled transaction list when a batch exists and transaction details when a sample exists; its message identifies probes that could not run on an empty account. It imports no payments and proves only the methods actually checked.
4. **Import reporting data** queues a local import. Default: previous seven days of settlements, current unsettled transactions and all previously observed nonfinal payments. Optional UTC dates permit windows of at most 31 days. Refresh to see completion/failure.
5. Select a UTC reporting day to inspect settlement totals by known currency/status, current statuses of payments submitted that day, source transactions and batches. Totals cover all imported rows; tables show at most 100 transactions and 30 batches. Unknown currencies are excluded from totals.
6. Enable daily reconciliation only when ready. The existing Solid Queue recurring configuration runs it at **06:20 America/New_York** for active tenants with saved, approved, explicitly enabled credentials. Deploying this code does not automatically enable any reporting account. Keep daily imports disabled until credentials are saved and reporting access is verified.

Removing credentials disables daily reporting and retains imported provenance. Changing setup cancels queued imports using the previous version; stale in-flight imports cannot commit over a changed setup. A busy database or unexpected job infrastructure failure remains visible through normal job failure handling.

## Supported data and limits

| Data | Implemented behavior / remaining gap |
| --- | --- |
| Sales/payment amounts | Stores source authorization and settlement amounts, transaction type and current status. Does not create item sales or inventory movements, avoiding duplicate retail/Shopify sales. |
| Refunds | Separate source transaction IDs, positive source amounts, refund type/status, and `refTransId` linking the original where supplied. No refund request exists. |
| Voids | Preserves `voided` status; revisits observed pending IDs even if omitted from current lists. No void request exists. Unobserved historical voids/declines that left unsettled reporting may be absent; use portal exports to audit. Actual void execution time is unavailable in the imported detail contract. |
| Settlement batches | Batch ID, settlement UTC time/state, payment method and allowlisted statistics. Batch settlement is not confirmation of a net bank deposit. |
| Tips | Official transaction-detail schema includes optional `tip.amount`. Import preserves a returned amount; absence stays NULL/Unknown. Actual account/processor population remains unverified. Never infer a tip by subtracting totals. |
| Customer surcharge | Preserves optional `surcharge.amount`; docs describe processor-specific support. This is a customer charge, not the merchant's processing fee. |
| Processing fees / payouts | No transaction-detail processing-fee or net-deposit contract was found in the reviewed schema. Not calculated or imported. Reconcile processor statements separately. |
| Currency | Detail lacks a per-payment currency. Uses merchant currency only when exactly one is enabled; otherwise NULL/Unknown, excluded from totals. |
| Provenance | Tenant + sandbox/production + verified Gateway ID + source transaction/batch ID are uniquely indexed. Retains original refund reference, source type/status, UTC dates, observed time and status-change history. No raw response/customer/card/contact data is stored. |
| Replay / concurrency | Fetches all requested data before an atomic local write; unchanged replays update existing observations. Setup version guards and unique indexes prevent concurrent/stale duplicate imports. OAuth credential rotation is a separate encrypted write before import. |
| Pagination | 1-based page offsets, 1,000/page, first-page total validation; repeated/incomplete pages fail rather than silently truncate. Limits: 100 pages/list and 20,000 unique transaction details/import. Live changes during paging may require retry. |
| Historical coverage | Daily overlap is seven days; outages longer than that require explicit backfill in windows up to 31 days. Vendor history retention limits apply. The endpoint has special inclusive-midnight behavior; explicit date inputs use 23:59:59Z as the last instant. |

Daily totals reflect the **latest imported state**, not a historical ledger of every gateway event. Charges and refunds are shown separately; no net-deposit or complete accounting-ledger claim is made. C-Trax supplies retail item/inventory truth; a gateway transaction cannot establish item quantities.

## Verification

Local validation: 835 SQLite Rails tests / 6,077 assertions passed; all 444 Ruby files passed repository RuboCop. Generated product-site consistency, 19 documentation-page link checks and `git diff --check` passed. PostgreSQL execution is deferred to repository CI.

Official schema and reference were downloaded directly over HTTPS. Synthetic API fixtures test pagination, source IDs, settlement/refund/void transitions, optional tips, exact decimal parsing, merchant mismatch, tenant/environment isolation, atomic failures, setup changes, OAuth read scopes/refresh rotation, bounded TLS transport and sanitized errors. Request/integration tests cover encrypted blank forms, explicit saves, queued imports, read-only permissions and daily totals beyond the display limit. Portal reporting visibility was inspected, but live API entitlement, processor field population, bank deposits and initial OAuth onboarding remain unverified. Existing Transaction Keys are not redisplayed by the portal; obtain the existing key securely from the owner or current checkout integration instead of rotating it during setup.

## Official sources

- [Transaction reporting overview](https://developer.authorize.net/api/reference/features/transaction-reporting.html)
- [API reference — transaction reporting](https://developer.authorize.net/api/reference/index.html#transaction-reporting)
- [Transaction Details API account feature](https://account.authorize.net/helpCP/Account/Settings/Security_Settings/transaction_details_api.htm)
- [Live API schema](https://api.authorize.net/xml/v1/schema/AnetApiSchema.xsd) — `transactionDetailsType`, `batchDetailsType`, `batchStatisticType`, `merchantAuthenticationType`.
- [OAuth registration, read permissions and token refresh](https://developer.authorize.net/api/reference/features/oauth.html)
- [Merchant OAuth permissions and owner/admin approval](https://support.authorize.net/knowledgebase/article/KA-07428/)
- [API Login ID and Transaction Key capabilities and rotation](https://support.authorize.net/knowledgebase/article/000001271/en-us)

The OAuth guide and merchant support article disagree about fixed token lifetimes. The connector refreshes once per reporting operation instead of assuming a lifetime; it fails closed on denied/expired refresh credentials.

Reviewed schema SHA-256: `c9c76cdbeba1f030bb453cdeec963457b9f85c6799db9b3888b0ade1a635a1fa`.
