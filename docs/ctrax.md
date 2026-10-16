# C-Trax read-only connection

See [retail screens, private tipping and daily register reconciliation](ctrax-retail.md) for the paired POS preview and sales/report importer.

The owner selected C-Trax inventory as the retail physical-count reference. C-Trax stock is kept separately from Shopify and Square. Approving a physical count records an audit worksheet and does not modify any platform's stock.

## Set up

1. Open **Settings → POS & payment connections → C-Trax** (`/pos_connections/ctrax`).
2. Enter the store's exact HTTPS API origin from the portal configuration, such as `https://your-store.api.cannatrax.net`, and a C-Trax user authorized to read the stores. Prefer a dedicated user with narrow read permissions.
3. Authorize Rupert's read-only use and save. Secrets use the existing encrypted tenant connection storage, are filtered from Rails request instrumentation, and are never refilled into the form. Saving does not contact C-Trax.
4. **Check read access** authenticates and summarizes the optional TRX merchant account list. **Sync stock** separately verifies stock access and imports all accessible stores' paginated variants.
5. Open **View C-Trax stock**, review the store and read timestamp, then **Prepare physical count**.

Select **Sync C-Trax stock every 30 minutes** to enable the production Solid Queue recurring job at minutes 0 and 30. Both the worker and recurring scheduler must be running. The setting alone does not start a worker or deploy code. Development does not run the production recurring schedule. Manual syncing and enabling the hourly setting require both settings write and inventory write permission. Removing credentials disables hourly syncing.

Each run logs in afresh; its bearer token exists only in the short-lived client object. A browser session is not a worker credential and cannot keep a scheduled sync authenticated. Credential changes invalidate checks and concurrent older syncs. No login cookies or session storage are extracted from the browser.

## Merchant connection versus stock

[C-Trax identifies TRX as Transaction Services](https://c-trax.com/payments/). Its merchant setup fields—Client ID, Username, Password/Token, Algorithm, optional mode/key/IV—configure a payment-vendor relationship. They are separate from C-Trax user login.

| Need | Data source |
| --- | --- |
| Variants, SKU/barcode, store stock | C-Trax store API; stock connector implemented here |
| Retail orders, refunds, cash/card totals, employee tips | C-Trax structured order/report endpoints; implemented by the separate daily reconciliation importer |
| Processor settlements, deposits, actual fees | TRX reporting API or export; technical contract and access still need verification |

[TRX advertises gateway/API integration and transaction reporting](https://www.trxservices.com/blogs/a-complete-guide-to-integrated-payments-for-isvs-and-saas-companies), but no public technical contract matching these merchant credentials was established. A successful merchant connection does not prove read access to settlements or fees. Rupert never saves the raw merchant connection-status response because it may contain merchant credentials; only account counts are returned by its check.

## Contract evidence and limits

The connector follows the publicly served C-Trax Serv 2.0 admin client, observed version 2.0.86 on October 15, 2026. This is an observed native portal contract, not a claimed supported partner API. [C-Trax advertises Open API integration](https://www.c-trax.com/dispensary-analytics/), but third-party authentication, stability, rate limits, and service-account support remain unverified. Vendor confirmation can replace the transport without changing source identity or count semantics.

- `POST /api/auth/login`: `{username, password}`; native response uses `token` and `permissions.accessible_stores`.
- `GET /api/v1/stores/{id}/productVariants`: `page`, `per_page`; native pagination uses `data`, `current_page`, `last_page`, `total`. Stock comes from `store_stock.quantity`, not a global product aggregate. Store attribute overrides are respected for SKU, barcode and stock tracking when the native `FLAG_MASTER_PRODUCT_LIST` feature is enabled.
- `GET /api/v1/stores/{id}/paymentVendors/trx/connectionStatus`: optional production/sandbox merchant lists; account counts only.
- Daily reconciliation read paths include `/api/v1/stores/{id}/orders`, `/api/v1/registerSessions`, `/api/v2/analytics/reports/sales.general.summary`, and `/api/v2/analytics/reports/oneOff/employeeTips`. Orders/registers/general reports are implemented in the daily importer; employee tips remain a separate research endpoint.

Only the login endpoint uses POST. All business reads use GET. The client pins requests to a validated C-Trax HTTPS origin, verifies certificates, ignores proxy environment variables, follows no redirects and makes no automatic retries. Limits are 20 stores, 200 pages/20,000 variants per store, 2 MiB per response, 32 MiB per client session and a 90-second request budget. Unexpected schemas, missing pages, changing totals, duplicate IDs or authorization failures retain all prior local snapshots. The limits can reject larger accounts; do not silently truncate them.

Every store is fetched and validated before a transaction publishes the local snapshots. This does not make remote pagination a point-in-time transaction: concurrent C-Trax sales can change stock while pages are being read, even if totals remain unchanged. The UI identifies the read start time. Stock shown is a dated mirror, not a promise of current on-hand stock.

## Count identity and data quality

- Native identity includes API origin, store ID and variant ID. A different C-Trax origin creates distinct store locations.
- Missing source SKUs remain missing. Worksheets use `ctrax:<variant-id>` as a local row key; Rupert never writes synthetic SKUs to C-Trax. Barcode scans resolve only within the selected store snapshot.
- Signed source quantities are preserved. A physical count starts at zero when mirrored stock is negative; the comparison still retains the negative stock.
- Unknown quantity, unverified/disabled stock tracking, duplicate aliases, changed identity, fractional stock and quantities outside the whole-unit worksheet range produce no numerical delta.
- Submission freezes store/variant identity, source quantity and mirror time. Later synchronization does not rewrite a submitted comparison.
- Source exports may have missing SKUs and may be filtered to listed products. Do not infer a complete native-ID stock snapshot from a CSV with no variant IDs. The [official export guide](https://intercom.help/C-TraxServSupport/en/articles/9315977-how-to-export-all-products-and-variants) provides a manual fallback for review, not an invented API contract.

## Recovery and private backups

The public source repository stores this contract and implementation. Keep account-specific notes and original exports in the owner's verified private Drive or a verified private repository; never commit production credentials, live merchant payloads, customer data, or browser tokens. A notes/export backup cannot restore an expired login. Decrypting a Rupert database backup also requires its original Rails encryption keys; keep those in a secret manager or protected deployment backup, not Git.

For supported unattended access, request C-Trax Serv 2.0 read-only integration documentation and service-account authentication for store stock, orders and reporting. Request TRX reporting documentation/scopes separately for settlements, deposits and fees. No vendor request is sent automatically.
