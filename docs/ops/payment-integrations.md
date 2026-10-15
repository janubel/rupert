# POS and payment account connections

Reviewed 2026-10-15. This release prepares provider accounts for later setup. It does not claim that any account has been connected or that Rupert can replace the live payment terminal.

## Systems named in the operator requirements

The business described C-Trax POS with a PAX terminal and Valmar processing, and Shopify website payments through Valmar. SwipeSimple was a proposed replacement option. KORONA and Cova were evaluation candidates. Square was a previous provider. These are business-reported relationships; they do not establish current merchant approval, supported hardware or a vendor support deadline.

## Implemented connection paths

| Provider | Rupert setup now | What remains before operational use |
| --- | --- | --- |
| Valmar | Merchant reference, requested/approved access record and gateway choice; link to the official merchant portal and gateway guides. | Confirm the actual gateway and its API contract. Valmar supports multiple arrangements; there is no assumed universal Valmar login/API. |
| PAX | Terminal model/device reference and developer-access preparation. | Confirm installed payment application, processor and approved SDK/bridge, then use a test terminal. No terminal commands are implemented. |
| C-Trax | Store/access preparation and official vendor documentation links. | Obtain account-specific Open API authentication, scopes, sample responses and export contract. No speculative endpoint is called. |
| SwipeSimple | Link to the existing transaction CSV importer. | Export the supported report and reconcile imports. SwipeSimple does not publish a payments integration API. |
| KORONA | Encrypted dedicated API credentials and explicit organizational-unit read-access check. | Trial/merchant account, correct region endpoint, approved read permissions; catalog/sales adapters and payment/terminal validation are separate work. |
| Cova | Encrypted approved integrator onboarding credentials and explicit company-location read-access check. | Approved intended integration use and Onboarding Package; business-data adapters and payment/terminal validation are separate work. |
| Shopify | Existing connection settings; website payment processing stays separate. | Existing tenant client-credential setup and an explicit sync when ready. This release adds no new Shopify OAuth login. |
| Square | Existing manual-token connection settings. | Account eligibility and a valid token. Rupert does not implement automatic OAuth login/token renewal. |

## Set up an account when ready

Open **System → POS & payments** or **Connections → POS & payments**. Review the provider, record the merchant/store or terminal reference and select the actual account environment. A trial/test label does not create a sandbox; obtain the correct test credentials from the vendor. For Valmar, confirm which gateway serves the account before choosing an adapter. Recording a gateway does not configure the existing Authorize.net checkout or enable charges.

Only an active workspace administrator with settings write permission can save details, check API access or remove saved credentials. The vendor access checkboxes are operator records, not automated proof of approval. Saving stays local: it does not start a sync, contact a vendor, send an access request or initiate a payment. Existing onboarding now follows the same explicit-save behavior.

KORONA requires the dedicated API v3 endpoint, account UUID, API login and API password from its widget. Cova requires its approved Onboarding Package: Company ID, client ID/secret and dedicated API username/password. Do not substitute ordinary merchant passwords, and do not use transient KORONA External Form credentials. Saved values stay blank in the forms; blank inputs keep previous values. Changing environment clears previous API credentials. Remove saved credentials clears Rupert's copy and read-check result; revoke vendor access separately at the provider when needed.

## What the checks prove

**Check read access** is an explicit action. KORONA makes one HTTP Basic GET to the first organizational-unit page at the validated account endpoint. Cova obtains a short-lived OAuth token from its documented onboarding authentication endpoint and then reads the selected company's locations. The Cova access token stays in memory for this request; refresh/access tokens are not stored or returned.

A successful check establishes access to that resource at that time. It does not prove catalog, sales, report, refund or payment permissions, terminal compatibility, settlement, or primary POS readiness. No customer, catalog or location data is imported by the check. Provider responses and credentials are not displayed in errors. Real account checks and checkout acceptance have not been performed in this release; tests use vendor-contract fixtures and synthetic credentials.

## Security and SQLite operation

Credential JSON is encrypted with the existing Rails encryption keys and scoped to the tenant. Request logging filters credential containers and raw settings imports; forms and responses prevent caching. Keep existing encryption keys with protected backups so recovery can decrypt saved accounts. The legacy settings cache is keyed by tenant to prevent same-thread context switches from reusing another store's credentials.

The provider request runs outside a database write transaction. Check results use one versioned conditional update, so an in-flight check cannot restore verification after credentials change or are removed. Endpoint restrictions, verified TLS, no proxy/redirect following, short network timeouts and bounded response bodies constrain read checks. No background job or retry silently contacts a provider.

## Official provider sources

[KORONA API-user setup](https://manual.koronapos.com/how-can-i-integrate-with-korona-pos-api-apiv3-widget/), [KORONA organizational-unit contract](https://github.com/COMBASE/cloud-api-v3-js-client/blob/master/docs/OrganizationalUnitsApi.md).

[Cova approved onboarding and terms](https://api.covasoft.net/GetStarted), [Cova authentication](https://api.covasoft.net/Documentation/Api/POST-v1-oauth2-token), [Cova company locations](https://api.covasoft.net/Documentation/Api/GET-v1-Companies%28CompanyId%29-Locations). Cova must approve Rupert's intended use under its integration terms before production use.

[Valmar gateway guides](https://vlmr.com/knowledge-base/), [Valmar client portal](https://app.valmarpayments.com/), [PAX developer access](https://www.pax.us/), [PAXSTORE developers](https://www.paxstore.us/developer), [C-Trax Open API statement](https://www.c-trax.com/dispensary-analytics/), [SwipeSimple public API statement](https://support.swipesimple.com/hc/en-us/articles/27117544574487-Does-SwipeSimple-have-a-public-API-for-integrations).
