# Authorize.net read-only reconciliation

**Live setup and additional history pulls remain paused by the owner, reaffirmed October 16, 2026.** The controls below describe a later authorized resume. See the [API investigation and implementation record](https://github.com/techmore/rupert/blob/main/docs/ops/authorize-net-api-investigation.md) for portal verification versus server API authentication and remaining gaps.

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

### Shared checkout credentials and Shopify

Authorize.net's [Shopify payment-app guide](https://www.authorize.net/support/shopify-platform-update.html) requires an API Login ID and Transaction Key. The same merchant credentials can serve multiple sites. Generating a replacement Transaction Key expires the old key immediately when requested, or automatically after 24 hours. That overlap only delays disruption: every checkout still using the old key must be updated before it expires. Never rotate a key to obtain reporting access.

The merchant portal cannot redisplay an existing Transaction Key. First inspect Shopify **Settings → Payments** read-only to identify the active provider, then verify its account mapping without revealing secrets. This store-specific dependency remains unverified pending Shopify sign-in. Rupert's Shopify catalog/order app credentials are separate from the payment app's gateway credentials. Saving the existing key in Rupert's encrypted reporting form does not rotate the gateway key; the key still has payment-processing capability. Vendor-enforced reporting-only access requires approved OAuth `read` credentials, whose initial onboarding is not implemented here.

Shopify's Payment ID and Authorize.net's transaction ID are distinct. The current payment app may place Shopify's Payment ID in the gateway transaction description. This importer preserves gateway IDs but does not retain free-text descriptions or automatically match Shopify orders; that cross-system reconciliation remains a gap.

All integration secrets use `PosConnection.credentials_json` and Rupert's existing Rails encryption keys. Forms remain blank, request parameter containers are filtered and responses prohibit caching. OAuth access tokens live only in memory; refreshed refresh tokens are saved encrypted with a setup-version check. Preserve production encryption keys when backing up.

## Operator workflow

1. Sign into the official [Merchant Interface](https://account.authorize.net/). Inspect user role, reporting access, Gateway ID and existing authorized applications without changing settings. Where the interface exposes Transaction Details API availability, inspect whether it is already enabled; do not change it automatically. Partner access is a separate login/entitlement.
2. In Rupert, select environment, enter the numeric **Gateway ID** as the merchant reference, choose authentication method and save to reveal its credential fields. Confirm approved integration access and enter credentials directly in the encrypted form. Blank fields retain saved values. Environment/method changes clear old credentials.
3. **Check read access** verifies merchant identity, recent settled batches and the unsettled transaction list. It probes a settled transaction list when a batch exists and transaction details when a sample exists; its message identifies probes that could not run on an empty account. It imports no payments and proves only the methods actually checked.
4. **Import reporting data** queues a local import. Default: previous seven days of settlements, current unsettled transactions and all previously observed nonfinal payments. Optional UTC dates permit windows of at most 31 days. Refresh to see completion/failure.
5. Select a UTC reporting day to inspect settlement totals by known currency/status, current statuses of payments submitted that day, source transactions and batches. Totals cover all imported rows; tables show at most 100 transactions and 30 batches. Unknown currencies are excluded from totals.
6. Enable automatic reconciliation only when ready. The Solid Queue recurring configuration runs it **every five minutes** for active tenants with saved, approved, explicitly enabled credentials. Deploying this code does not automatically enable any reporting account. Keep automatic imports disabled until credentials are saved and reporting access is verified.

Removing credentials disables automatic reporting and retains imported provenance. Changing setup cancels queued imports using the previous version; stale in-flight imports cannot commit over a changed setup. A busy database or unexpected job infrastructure failure remains visible through normal job failure handling.

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

Local validation: 835 SQLite Rails tests / 6,077 assertions passed; all 444 Ruby files passed repository RuboCop. Generated product-site consistency, 19 documentation-page link checks and `git diff --check` passed. The application and CI support SQLite only.

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


## Shift commissions and event reporting (October 15 follow-up)

The dashboard now has a payroll-read permissioned **Shift commissions · today** widget. It recomputes from local orders and clock shifts every 30 seconds, with a single selected sales source and currency. The full commission date-range preview refreshes at the same interval. The existing rule remains each worker's independent 1%, rounded half-up per order, on imported positive item unit prices × quantity before order-level discounts. Matching uses sale occurrence time and half-open shifts; each overlapping worker gets their own percentage. Unpaid, refunded and invalid-price orders remain excluded. Separately recorded tax, shipping and tips are not added. Source timestamps, absent shifts and absent imports are visible. This is an estimate, not an automatic payroll posting or disbursement.

Authorize.net observations do not establish item subtotals or employee entitlement. They never create a second canonical sale or commission. Gateway-to-order matching, C-Trax sales attribution and native SwipeSimple payment-export attribution remain unverified. Do not sum source pools that may contain the same sales. The live SER8 inspection found manual portal exports, no configured reporting API connection and no clock shifts at the time of inspection; those prerequisites must be completed before claiming coverage.

An optional existing **Signature Key** can be saved encrypted alongside reporting credentials. It is blank on display, retained on blank submission and removed with disconnect. It is not required for polling. Save approved reporting credentials, check read access and enable automatic reconciliation. Rupert then displays its HTTPS callback `/webhooks/authorize_net/<connection ID>` in the connection form. Configure the merchant portal to deliver payment authorization, capture, refund, void and fraud events to that callback. This implementation does not create a vendor subscription, generate/rotate keys or change vendor settings. Reuse the existing Signature Key; initial key access and live event delivery remain unverified.

The receiver validates HMAC-SHA512 against the exact received body using the decoded Signature Key (with legacy text-key callback compatibility) and constant-time comparisons. It bounds accepted payload size, allows documented payment events only, and queues only the transaction ID and account/signing-key scope. No webhook monetary amount becomes financial evidence. The job verifies current merchant identity and fetches current transaction details through the independent read-only client. Repeated and out-of-order deliveries refresh the same source transaction; older observations cannot replace newer ones. Event jobs retry reporting errors up to five attempts. Replaced accounts/keys, disconnected connections, paused reporting and inactive tenants cancel queued events. A targeted event does not advance the full reconciliation timestamp. Failures remain visible in job administration; five-minute reconciliation catches settlements and revisits pending observations. Settlement events are not presumed to exist.

The Authorize.net report section also refreshes every 30 seconds, without reloading or replacing the connection credential form. Polling begins only for explicitly enabled, approved connections with saved credentials. This code does not claim live merchant credentials, verified subscriptions, complete sales attribution or bank deposits.

Official event and signature contract: [Authorize.net Webhooks](https://developer.authorize.net/api/reference/features/webhooks.html).


## Matching captured payments to sales

The payroll-permissioned **Match Authorize.net payments to sales** page (`/authorize_net_sale_links`) links one production API charge to one existing canonical sale. Exact invoice references, currency and full gross amount produce review suggestions only. A payroll writer confirms the exact sales source/reference and a private receipt-evidence note. Amount/time coincidences alone are never treated as identity. Partial/split tenders and unknown currencies cannot establish a match. The observed `order.invoiceNumber` is retained encrypted; free-text descriptions and customer/card data are not imported.

Active payment and sale matches are unique within the workspace. A correction revokes a match without deleting it; the previous reviewer, note and link remain. The confirmation and revocation are logged locally. Match creation never creates or changes an order, tender, inventory movement or payroll posting. Cross-workspace references and sandbox payments are rejected.

For an already paid/fulfilled sale, a confirmed match replaces the commission preview's canonical tender proof with current gateway proof; the gateway amount is never added to the merchandise subtotal. Captured-pending-settlement and settled charges qualify only while the full amount and currency still agree with the sale. A linked void, decline, changed amount/currency or any observed pending/settled refund referencing that original payment removes the sale from the estimate. A voided refund does not exclude it. Source sale status, valid item prices, recorded canonical refunds and shift boundaries still apply. A gateway authorization alone does not turn a placed sale into a paid one.

Signed events update the same payment record, so reviewed matches are rechecked automatically when the commission frame refreshes. Newly arriving payments without trustworthy shared identifiers require receipt review once. This implementation does not claim automatic identity matching where the provider omitted identifiers, or complete refund/commission coverage before source access and shifts exist. The existing manual gateway exports had no populated invoice/order numbers that could match canonical sales; they cannot be used to certify live links.

Activation order: sign in to the correct merchant account; obtain existing integration credentials from the checkout operator or its secure record; choose production and the verified Gateway ID in Rupert; save and check reporting access; import production observations; enable the schedule; save the existing Signature Key and register the displayed HTTPS callback for payment events; verify actual delivery and one existing sale match; have workers record shifts. No test charge, key rotation or vendor-account reset is part of this rollout.
