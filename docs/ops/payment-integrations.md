# POS and payment account connections

Reviewed 2026-10-15. This release prepares provider accounts for later setup. It does not claim that any account has been connected or that Rupert can replace the live payment terminal.

**Start with the plain-English guide:** [who handles a payment, how Valmar and Authorize.net fit, and who to contact](https://techmore.github.io/rupert/payment-basics.html). A gateway is the secure connection from checkout; a processor runs the payment-processing systems. Confirm the existing account arrangement with Valmar before selecting a gateway or buying another service.

## Systems named in the operator requirements

**Long-term owner direction, October 15, 2026:** Rupert should probably retain Valmar and Authorize.net as ongoing integrations. This is a planned objective (roadmap F64), subject to confirmed account/gateway mapping and supported access. Preserve separate SwipeSimple sales/invoice evidence, gateway payment evidence and processor deposits so overlapping records are not counted twice. C-Trax remains the retail inventory reference. See the [integration research and vendor-access requirements](https://github.com/techmore/rupert/blob/main/docs/ops/swipesimple-integration-research.md). This note does not activate payments, change merchant settings or enable hourly SwipeSimple intake.

The business described C-Trax POS with a PAX terminal and Valmar processing, and Shopify website payments through Valmar. SwipeSimple was a proposed replacement option. KORONA and Cova were evaluation candidates. Square was a previous provider. These are business-reported relationships; they do not establish current merchant approval, supported hardware or a vendor support deadline.

## Deep Run Hemp: historical NMI checkout evidence

Email evidence reviewed October 16, 2026 establishes that Deep Run Hemp's separate WooCommerce store completed a card sale through NMI on July 23, 2026. This is historical store evidence; it does not establish a live Rupert connection or identify the gateway serving the separate Valmar account described above.

| Date | Evidence | What it establishes |
| --- | --- | --- |
| June 16, 2026 | Andre's "Host my own store" email | General application guidance named business information, bank statements, product details and the website. It is not Next Stage's original underwriting checklist or proof of which documents were submitted. |
| July 21, 2026 | "Fw: Approval Notification - Deep Run Hemp", forwarding Next Stage Payments underwriting | The merchant account was approved. NMI activation and an API key for the website developer were the next steps. |
| July 22, 2026 | "Fw: Deep Run Hemp - NMI Gateway", forwarding Next Stage support and technical guidance | The intended stack was DigitalOcean, WooCommerce and NMI, with the integration requirements below. |
| July 23, 2026 | Matching "Deep Run Hemp Transaction Receipt" and "Your Deep Run Hemp order has been received!" emails | The gateway receipt reports a completed card sale, and the matching store confirmation explicitly names "Credit Card (NMI)". Together they demonstrate that NMI checkout was working for at least one sale on that date. |
| October 14, 2026 | Andre's "Crypto gateway" email | Alternative crypto gateways were being explored. The email does not say NMI failed, was replaced or was disconnected. |

Next Stage's July 22 setup guidance requested:

| Requirement | July 22 guidance |
| --- | --- |
| Credentials | NMI API Key and Security Key obtained from the merchant dashboard for the developer's integration. Preserve the provider's historical wording; confirm the exact credential fields required by the chosen plugin rather than assuming two distinct keys are always necessary. |
| Plugin | An installed and activated third-party NMI payment gateway plugin for WooCommerce. |
| SSL | A valid SSL certificate on the DigitalOcean server. |
| Caching | Cache exclusions for WooCommerce /cart/ and /checkout/ so checkout sessions can work. |
| Server | Outbound HTTPS on port 443 and an active PHP cURL extension. |

The broader email search found no Authorize.net setup tied to Deep Run Hemp and no original Next Stage application packet. March DashNex/Cloudflare access and purchase failures predate this WooCommerce evidence and should not be treated as a later NMI failure.

**Status:** merchant approval confirmed; historical NMI store checkout demonstrated; current account health, bank settlement, refunds, tipping, terminal compatibility and Rupert integration remain unverified. Next Stage supplied the approval and integration support, but these emails do not identify the backend processor or acquiring bank. Preserve store orders, gateway transactions and processor deposits as related evidence, not additional sales to sum together.

Before using this history for Rupert's payment work, confirm the merchant/business and account environment, approved integration access, current credentials and supported payment features. Match historical gateway activity to settlement evidence separately. Keep original emails, private source links, customer/order details, gateway identifiers and credentials outside public Git; this section deliberately records only the sanitized findings.

## Connecting the existing Deep Run Hemp account to Rupert

Investigation dated October 16, 2026: the historical NMI account is a candidate for Deep Run Hemp checkout in Rupert. Confirm its current status and approved scope with Next Stage before enabling production charges. The July sale does not authorize routing another business's sales through this account or demonstrate retail terminal support.

| Required input | What to establish |
| --- | --- |
| Account and approval | Next Stage confirms the account is active, the merchant is Deep Run Hemp, the permitted products and currency, the intended Rupert checkout domain/channel, and any required website review or service activation. Confirm backend processor/acquiring arrangement and fees rather than assuming them. |
| Application credentials | Create dedicated Rupert keys under the correct merchant user: a public tokenization key for browser card entry and a private payment API key for the server, with the permissions needed for the chosen integration. Keep WooCommerce's keys independent. Store the private key encrypted in tenant-scoped settings. |
| Testing access | Obtain a separate NMI sandbox merchant and its matching keys. Confirm Payment Component/REST API access for this account; public examples and profile-query success do not prove payment permissions. |
| Reconciliation access | Confirm the supported transaction lookup/reporting method and, if available, transaction webhooks with their signing key. Establish the processor/account to use if more than one is configured. |

NMI currently recommends its [Payment Component](https://docs.nmi.com/docs/payment-component) with its REST API for new integrations, rather than starting with Collect.js. The public tokenization key is used in the browser; the private key remains server-side. See [frontend integration](https://docs.nmi.com/docs/integration-guide-implement-frontend), [API authentication and separate application keys](https://docs.nmi.com/reference/authentication), [payment examples](https://docs.nmi.com/docs/payment-code-examples) and [transaction/settlement webhooks](https://docs.nmi.com/reference/overview). Some published component examples contain template package names; verify the actual supported SDK/package and contract in sandbox before implementing them.

**Current code gap:** main's NMI connection performs a merchant-profile read only. Warehouse card checkout calls AuthorizeNetClient and uses Authorize.net tokens. The separately inspected POS development code also uses Authorize.net in Pos::Gateway, Pos::CardPayment and PosSetting. Entering an NMI key in those Authorize.net fields cannot connect NMI.

The implementation should add an explicit NMI provider/account selection independent of the Valmar label, public tokenization settings, and an NMI gateway adapter. Reuse cart pricing, tax/tip confirmation, receipt and inventory bookkeeping where appropriate, while adding provider-specific charge and transaction-status handling. Compute the payable amount server-side, submit a tokenized sale, record the gateway transaction reference, and mark the order paid only after verifying the matching account, amount, currency, reference and successful sale status. Keep charges outside database locks. Retain unresolved payment attempts across timeouts and process restarts; reconcile before allowing another charge. Do not assume an order reference or an onboarding API's idempotency header prevents duplicate payment requests.

For a first checkout release, implement card sales plus the transaction lookup/reconciliation needed to recover uncertain outcomes. Test approvals, declines, token reuse, double-clicks, concurrent submits, lost responses and recovery, tenant/account isolation, exact totals including tax/tip, and one-time receipt/stock effects. Refund/void operations need their own verified implementation and acceptance. HTTPS, required browser policy allowances and no checkout caching are part of deployment. Once sandbox acceptance passes and Next Stage confirms scope, perform an explicitly owner-authorized production acceptance sale and independently verify capture/settlement and any reversal. Do not treat a successful profile check or the July WooCommerce sale as Rupert acceptance.

An NMI browser checkout is not an EMV/contactless PAX terminal integration. Confirm the terminal's installed application, processor and supported NMI device integration separately before promising card-present payments or rates.

## Implemented connection paths

| Provider | Rupert setup now | What remains before operational use |
| --- | --- | --- |
| Valmar | Select the confirmed Authorize.net or NMI gateway, save encrypted gateway credentials and run an explicit credential/profile check. Other gateway choices retain preparation only. | Confirm the actual Valmar gateway and approved account environment. A check does not enable payment collection or a terminal. |
| PAX | Terminal model/device reference and developer-access preparation. | Confirm installed payment application, processor and approved SDK/bridge, then use a test terminal. No terminal commands are implemented. |
| C-Trax | Store/access preparation and official vendor documentation links. | Obtain account-specific Open API authentication, scopes, sample responses and export contract. No speculative endpoint is called. |
| SwipeSimple | Native transaction/invoice CSV reporting with encrypted originals, replay protection and daily tender/tip/refund observations; prepared line-item sales imports remain a separate workflow. | Native source reports do not establish item lines, taxes, fees, bank settlement or unique invoice IDs. A supported unattended vendor feed is still required; hourly intake remains disabled. |
| KORONA | Encrypted dedicated API credentials and explicit organizational-unit read-access check. | Trial/merchant account, correct region endpoint, approved read permissions; catalog/sales adapters and payment/terminal validation are separate work. |
| Cova | Encrypted approved integrator onboarding credentials and explicit company-location read-access check. | Approved intended integration use and Onboarding Package; business-data adapters and payment/terminal validation are separate work. |
| Shopify | Existing connection settings; website payment processing stays separate. | Existing tenant client-credential setup and an explicit sync when ready. This release adds no new Shopify OAuth login. |
| Square | Existing manual-token connection settings. | Account eligibility and a valid token. Rupert does not implement automatic OAuth login/token renewal. |

See the [reviewed sales import and register report guide](https://techmore.github.io/rupert/sales-imports.html) for the supported CSV contract, sample file, preview/import workflow and source coverage limits.

## Set up an account when ready

[Open Rupert provider setup](https://rupert.stoverparc.org/pos_connections). Sign in with your authorized Rupert account.

Open **System → POS & payments** or **Connections → POS & payments**. Review the provider, record the merchant/store or terminal reference and select the actual account environment. A trial/test label does not create a sandbox; obtain the correct test credentials from the vendor. For Valmar, confirm which gateway serves the account before choosing an adapter. For Authorize.net and NMI, the saved gateway choice reveals its specific credential fields. Recording a gateway or checking it does not configure the existing warehouse checkout or enable charges.

Only an active workspace administrator with settings write permission can save details, check API access or remove saved credentials. The vendor access checkboxes are operator records, not automated proof of approval. Saving stays local: it does not start a sync, contact a vendor, send an access request or initiate a payment. Existing onboarding now follows the same explicit-save behavior.

KORONA requires the dedicated API v3 endpoint, account UUID, API login and API password from its widget. Cova requires its approved Onboarding Package: Company ID, client ID/secret and dedicated API username/password. Do not substitute ordinary merchant passwords, and do not use transient KORONA External Form credentials. Saved values stay blank in the forms; blank inputs keep previous values. Changing environment or Valmar gateway clears previous API credentials and check results. Supply fresh credentials for the selected gateway; fields from another gateway are not accepted. Remove saved credentials clears Rupert's copy and read-check result; revoke vendor access separately at the provider when needed.

## Valmar gateway credentials

Confirm the gateway with Valmar first. If it is Authorize.net, obtain the API Login ID and Transaction Key from the correct sandbox or production Merchant Interface. If it is NMI, obtain a merchant API Security Key and a provider-issued sandbox account for testing. An NMI API key may also permit payment operations; Rupert uses it only for its documented profile query here. The shared NMI demonstration key does not establish Query API access.

Choose the gateway and account environment, save the setup, then enter the required credentials. All saved values remain encrypted and blank in the form. No credential is copied into the older warehouse payment settings. Unconfirmed, SwipeSimple and other gateway selections expose no invented API connection.

## What the checks prove

**Check read access** is an explicit action. KORONA makes one HTTP Basic GET to the first organizational-unit page at the validated account endpoint. Cova obtains a short-lived OAuth token from its documented onboarding authentication endpoint and then reads the selected company's locations. The Cova access token stays in memory for this request; refresh/access tokens are not stored or returned.

The Valmar Authorize.net check sends only `authenticateTestRequest` with merchant authentication. Its successful API response verifies those credentials; it does not create, authorize, capture or refund a transaction. The NMI check sends only `report_type=profile` to the Query API and verifies the documented merchant-profile response. It does not query transactions, cards or a customer vault, and no returned profile/contact data is stored or displayed. Sandbox and production use fixed vendor endpoints.

A successful check establishes the specific credential or resource access checked at that time. It does not prove catalog, sales, report, refund or payment permissions, terminal compatibility, settlement, or primary POS readiness. No customer, catalog or location data is imported by the check. Provider responses and credentials are not displayed in errors. Real account checks and checkout acceptance have not been performed in this release; tests use vendor-contract fixtures and synthetic credentials.

## Security and SQLite operation

Credential JSON is encrypted with the existing Rails encryption keys and scoped to the tenant. Request logging filters credential containers and raw settings imports; forms and responses prevent caching. Keep existing encryption keys with protected backups so recovery can decrypt saved accounts. The legacy settings cache is keyed by tenant to prevent same-thread context switches from reusing another store's credentials.

The provider request runs outside a database write transaction. Check results use one versioned conditional update, so an in-flight check cannot restore verification after credentials change or are removed. Endpoint restrictions, verified TLS, no proxy/redirect following, short network timeouts and bounded response bodies constrain read checks. No background job or retry silently contacts a provider.

## Official provider sources

[KORONA API-user setup](https://manual.koronapos.com/how-can-i-integrate-with-korona-pos-api-apiv3-widget/), [KORONA organizational-unit contract](https://github.com/COMBASE/cloud-api-v3-js-client/blob/master/docs/OrganizationalUnitsApi.md).

[Cova approved onboarding and terms](https://api.covasoft.net/GetStarted), [Cova authentication](https://api.covasoft.net/Documentation/Api/POST-v1-oauth2-token), [Cova company locations](https://api.covasoft.net/Documentation/Api/GET-v1-Companies%28CompanyId%29-Locations). Cova must approve Rupert's intended use under its integration terms before production use.

[Valmar gateway guides](https://vlmr.com/knowledge-base/), [Valmar client portal](https://app.valmarpayments.com/), [PAX developer access](https://www.pax.us/), [PAXSTORE developers](https://www.paxstore.us/developer), [C-Trax Open API statement](https://www.c-trax.com/dispensary-analytics/), [SwipeSimple public API statement](https://support.swipesimple.com/hc/en-us/articles/27117544574487-Does-SwipeSimple-have-a-public-API-for-integrations).

[Authorize.net API reference](https://developer.authorize.net/api/reference/index.html), [official authenticateTest SDK test](https://github.com/AuthorizeNet/sdk-ruby/blob/master/spec/api_spec.rb#L28), [NMI Query API](https://docs.nmi.com/reference/query), [NMI production query example](https://docs.nmi.com/docs/terminal-management).
