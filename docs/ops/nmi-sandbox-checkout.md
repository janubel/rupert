# NMI sandbox checkout

Implemented October 16, 2026 on top of the customer-screen POS checkout. NMI production charging is blocked in the settings model, checkout preparation and gateway adapter. The adapter contains sandbox endpoints only; there is no production enable flag. Next Stage confirmation and a separately reviewed implementation are required before supporting live NMI payments.

## Implemented scope

The cashier prepares a repriced cart after the customer's private tax/tip review. The customer enters card details into NMI Collect.js hosted fields; Rupert receives only a token. The backend submits an NMI REST sale for the frozen server total, then verifies the corresponding Query API transaction, order reference, USD currency, card transaction type, successful sale action and exact amount. No database lock spans a gateway request.

Each attempt is stored before submitting a charge. Only the token's digest is retained. A decline requires a fresh token. A timeout, malformed response, held transaction or mismatch stays unresolved and blocks another charge. Scheduled/manual reconciliation reads by the durable order reference, plus transaction ID if known; multiple matches require review. No blind payment retries or assumed provider idempotency are used.

Sandbox receipts are explicitly labeled. They create no canonical sales/orders/payments, register revenue, stock allocations or C-Trax stock writes. Existing cash and Authorize.net behavior is preserved. This implementation adds NMI to the paired POS customer-screen checkout; the separate legacy warehouse checkout is still Authorize.net. It does not add PAX/EMV/contactless terminal support, refunds or voids.

## Set up a dedicated sandbox merchant

Ask Next Stage/NMI for a dedicated sandbox merchant with tokenization, REST payment and Query API permissions. Shared demonstration credentials do not establish Query API access. No dedicated sandbox credentials were available for the October 16 implementation, so vendor-connected acceptance remains pending; automated fixture tests are not a real sandbox sale.

In the store's POS checkout setup, select **NMI · sandbox only**, keep the environment **Sandbox**, and save the selection first. This clears incompatible gateway credentials and verification. Supply the sandbox account reference, exact expected sandbox company, private API security key and public tokenization key using the encrypted credential form. Do not paste keys into GitHub or chat, and do not reuse WooCommerce's application keys.

Run **Check gateway profile / hosted form setup**. This performs a read and compares the returned company name to the configured expectation. The documented profile response has no Gateway ID, so the operator-entered account reference is not independently verified. The read also cannot prove payment permissions or tokenization-key compatibility. After the profile check, explicitly enable **sandbox card tests only**.

Use a dedicated store/register and test catalog context when arranging acceptance. The two-screen **Demo** continues to simulate payments; it does not contact NMI. To exercise NMI sandbox, use the actual paired customer screen, confirm a tip and prepare a card checkout. Its payment button and completed receipt say **Sandbox**. HTTPS and uncached customer/payment routes are required for browser acceptance. No raw card parameters are accepted by the payment endpoint; unexpected card fields and credential containers are filtered from request logs.

Changing provider, environment or keys clears verification and disables cards. Unresolved card attempts block account/credential changes. Every NMI checkout is bound to the provider, account reference, environment and credential fingerprint captured at preparation. Reload the customer screen when changing accounts, public keys or providers.

## Acceptance and recovery

Use only NMI's published sandbox card fixtures. Verify approval and decline, exact tax/tip total, fresh tokens, repeated submission, interrupted response, later read-only reconciliation, expired customer pairing and tenant isolation. Confirm that the gateway sandbox transaction and Rupert sandbox receipt match and that no real sale/revenue/stock records were added. Check an uncertain outcome in the original sandbox account; do not submit another payment to discover what happened. Voids/refunds remain a vendor-portal operation outside Rupert's implemented scope.

Automated checks cover the gateway contracts, production rejection even when model validations are bypassed, encrypted settings, stale account/token callbacks, amount/order/currency mismatch, XML entity rejection, multiple transactions, read-only recovery and customer checkout routes. Run the relevant Rails tests and `node web/test/javascript/nmi_fields_test.mjs`; current CI runs the Rails suite against SQLite and the hosted-fields JavaScript test. A successful fixture run does not prove actual NMI account access, iframe tokenization, REST entitlement, settlement or current production readiness.

## Integration contracts

[NMI REST payment examples](https://docs.nmi.com/docs/payment-code-examples) explicitly accept Collect.js tokens under payment_details.payment_token. The sandbox-only adapter uses the REST sale endpoint with order_details.id as the durable attempt invoice. [Query API](https://docs.nmi.com/reference/query) supplies profile and transaction reporting, including order_id filtering and successful sale actions. [Collect.js advanced integration](https://docs.nmi.com/docs/advanced-integrations) supplies hosted field selectors and callbacks. [Authentication](https://docs.nmi.com/reference/authentication) describes separate public and private application keys.

NMI recommends its newer [Payment Component](https://docs.nmi.com/docs/payment-component) for new integrations, but the inspected public frontend examples still contain placeholder npm package/export names. This release uses the documented, supported Collect.js tokenization path with the REST API rather than inventing a package. Revisit the preferred component when its merchant-supported SDK contract is available.
