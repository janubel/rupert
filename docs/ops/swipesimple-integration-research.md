# SwipeSimple, Valmar and Authorize.net integration research

Reviewed October 15–16, 2026. This is a sanitized engineering investigation and an owner-requested roadmap record. It separates account observations, vendor documentation, working Rupert code and proposals. Public documentation cannot establish private account entitlements. No vendor access request has been sent, add-on purchased, credential generated or merchant setting changed by this investigation.

## Decision and owner objective

**Working now:** Rupert accepts the verified native SwipeSimple transaction and invoice CSV formats, keeps encrypted original documents and source provenance, prevents replay duplicates, and reports payment results and daily cash/card/unknown-tender and tip totals. The owner-authorized deployment and initial imports were completed on SER8. [Implementation PR #47](https://github.com/techmore/rupert/pull/47) and [migration correction #48](https://github.com/techmore/rupert/pull/48) are merged. The [release receipt](https://github.com/techmore/rupert/blob/codex/ser8-swipesimple-release/docs/ops/deployment-swipesimple-2026-10-15.md) records the combined release and validation; later deployments may advance its recorded revision.

**Not established:** a supported unattended hourly source feed for this SwipeSimple merchant account. The local CSV inbox is implemented but disabled. It is a consumer of delivered files, not a vendor downloader. A scheduler running every hour cannot make a manual export fresh.

**Owner direction, October 15, 2026:** Rupert should probably maintain long-term integrations with **Valmar and Authorize.net**. Record this as a planned product objective, subject to confirmation of the account arrangement and supported access. Valmar is the provider relationship and route to processor/reporting access; Authorize.net is a gateway integration target. SwipeSimple supplies wholesale/event operational evidence. C-Trax remains the retail inventory reference. This direction does not select a new processor, authorize gateway migration or enable payment writes. See roadmap item **F64** in `web/config/product_roadmap.json`.

The smallest remaining action for hourly SwipeSimple freshness is to ask the existing Valmar support contact for an approved reporting API/partner entitlement or automatic export-delivery contract for this account. Provide account identifiers privately. Obtain a sample payload/file and delivery documentation before implementing the producer. Merchant portal credentials alone do not establish API access.

## What was actually inspected

| Evidence class | Observation | What it establishes |
| --- | --- | --- |
| Authenticated merchant portal | Transactions, Invoices, Reports, account configuration and merchant Support Center were inspected read-only | Native exports and the provider support route are accessible; no reporting API key tab or hourly export control was found in the inspected areas. This is not proof that private partner access cannot exist. |
| Actual private exports | Native transaction and complete invoice CSVs downloaded through the portal, previewed, imported and reconciled | Real-format compatibility, encrypted byte-for-byte originals and replay protection. Only the supplied range/snapshot is proven; no all-time completeness claim. |
| Official demo | Native demo CSV structure and a Sale/Refund sharing a displayed transaction number | Sanitized fixtures can preserve the vendor shape; transaction number alone is insufficient for the observed sale/refund identity case. |
| Rupert code and release checks | Importer, reports, permissions, receipt storage, inbox job, migration rehearsal and combined adapter CI | Implemented behavior and successful initial deployment/import. Tests do not confer vendor access. |
| Public vendor/provider sources | API statement, exports, transaction semantics, ACH, reports, marketplace, partner resources and gateway reporting contracts | Product-level capabilities; account applicability must be confirmed separately. |
| Narrow connected-mailbox search | No matching SwipeSimple/CardFlight report or attachment messages found | Only that connected mailbox/search was checked. Report delivery to another user or mailbox remains unknown. |

Raw exports, customer/operator fields, merchant IDs, financial totals, secrets and private network/access details are excluded from this repository. The provider-linked interactive SwipeSimple training guide did not render sufficiently to verify its contents. Search failure or an unreadable video is recorded as unknown, not as a negative product capability.

## Candidate paths and readiness

| Path | Scope and cadence supported by evidence | Readiness for Rupert |
| --- | --- | --- |
| Native transaction/invoice CSV | Supported manual downloads; real files validated | Working fallback. Human export freshness; invoice export must be complete and unfiltered. |
| Public SwipeSimple reporting API | Official support says no public API [S1] | No general public connector to implement from merchant login. |
| Private partner/reseller feed | Reseller program and account-manager route exist [S10] | Possible vendor conversation, with no account-approved reporting contract established. Do not guess endpoints. |
| Scheduled batch/daily reports | Email reporting and manual CSV export documented; cadence follows batch close or daily cutoff [S5] | Useful reconciliation evidence. No verified hourly machine-readable delivery, invoice coverage or email attachment contract. |
| Sales Report CSV | Daily totals for subtotal, tax, discounts, tips, refunds and tenders documented [S6]; ACH guidance adds net ACH [S7] | Promising independent totals check. This is a different format, not currently accepted by the transaction/invoice importer. |
| QuickBooks Online bridge | Approved optional add-on; transaction sync is on demand, with narrower immediate invoice propagation [S11–S14] | Conditional accounting bridge; does not currently solve unattended hourly payment capture or historical backfill. |
| Appointments API / Zapier | Scheduling integrations and API are explicitly documented [S15] | Product-specific, not evidence of Payments transaction/invoice ledger access. |
| Valmar gateway / Authorize.net / NMI | Distinct gateway and processor-reporting paths [S16–S18] | Useful independent payment/settlement evidence after account mapping and access verification; not presumed to contain SwipeSimple cash/invoices. |
| NAB/IRIS processor reporting | Public tenant API specification and a separate Rupert implementation investigation [S19, R2] | Potential batch/deposit/chargeback source. Live API entitlement is unverified in that work; no automatic linkage to all SwipeSimple activity is established. |
| Browser robot / private web endpoints | No supported reporting automation contract found; current terms restrict scraping/crawling [S9] | Not implemented or enabled. Obtain a vendor-approved method rather than turning an interactive session into an assumed API. |

### Public API, partner access and historical SDKs

The June 26 public-API article describes a closed platform [S1]. Its broad statement about third-party integrations cannot be generalized to deny the marketplace integrations documented elsewhere. The defensible conclusion is that no **general public SwipeSimple Payments reporting API** has been established for Rupert.

Current reseller pages describe partner resources and account-manager contact [S10]. They do not supply the merchant reporting endpoints, authorization scopes, retention or delivery contract needed here. Earlier RAMP/onboarding references are not a current account reporting specification. CardFlight RAMP must also not be confused with the unrelated Ramp corporate-card company's API.

Historical CardFlight developer material is another false shortcut: CardFlight's own retrospective describes its SDK as a card-present payment-acceptance product and says it had stopped taking new integrations at that time [S20]. That dated history establishes neither current availability nor read-only access to an existing SwipeSimple merchant ledger. No legacy SDK, hidden browser endpoint, session cookie or inferred authentication scheme was used.

### Scheduled reports and export coverage

The batch guide distinguishes processors/products with batch reports from those with daily reports. Delivery within an hour **after batch close** is a delivery latency, not an hourly recurring feed [S5]. Report cutoff, event day, processor settlement and bank-deposit day may differ. We did not alter batch timing, recipient lists or report settings to force another cadence.

The transaction export has a documented 10,000-row ceiling, applies the current filters and omits linked-refund details, Payment Link detail fields and receipt history [S2]. History defaults to a recent range; user filters persist, and member access can be limited to the member's own transactions [S3]. Backfill needs deliberate ranges/account selection and coverage accounting, not a claim that the default download contains everything.

The Sales Report is a separate daily aggregate with useful tax/discount/adjustment components [S6]. It may support an independent reconciliation adapter after an actual account export is obtained and its schema verified. It cannot reconstruct transaction identities, invoice lifecycle or original documents. Scheduled report email content/attachment shape has not been verified; do not build a parser from a guessed email template.

### QuickBooks: useful bridge with upstream limits

The marketplace advertises on-demand sync and a $19.95/month add-on as reviewed, separate from any QuickBooks subscription [S11]. Provider participation and administrator access determine availability; the FAQ excludes historical sync [S12]. No subscription or account connection was created during this investigation.

Detailed reconciliation instructions explicitly require **Sync Now** for transactions [S13]. Invoice matching distinguishes immediate invoice creation/update from manually synced payments, refunds and voids [S14]. Marketing language about automatic sync is therefore insufficient evidence of an unattended payment feed. Ask which behavior and version would apply to this account.

Intuit documents OAuth-authorized company webhooks for Invoice, Payment, RefundReceipt and SalesReceipt, with notification verification [S21]. A future Rupert reader could use supported QuickBooks APIs after an authorized setup. That downstream capability cannot make missing upstream SwipeSimple payments arrive. QuickBooks IDs are accounting-source IDs unless an explicit SwipeSimple ID is preserved. The vendor add-on writes accounting records, so activating it is a separate business change even if Rupert subsequently only reads. Duplicate recognition against existing CSV evidence, customer/item mappings and invoice modes require review first.

### Valmar, Authorize.net, NMI and processor evidence

Valmar's knowledge base distinguishes its own gateway portal, SwipeSimple, Authorize.net, NMI, IRIS, MReports and Merlink [S16]. A credential or generic API claim for one system is not authorization for another. Confirm which merchant accounts and channels each gateway/processor actually serves, and obtain an explicit mapping with native source IDs.

Authorize.net documents batch lists, transaction lists, unsettled transactions, transaction details and batch statistics [S17]. This is a supported reporting surface worth retaining as a long-term Rupert integration. Its transactions must remain gateway evidence until matched to operational sales; an Authorize.net total and a SwipeSimple total may overlap. Refunds, voids, declined attempts, partial captures and settlement states must not be collapsed into one paid boolean. Portal login and API authentication are separate.

NMI has a documented Query API [S18], but this does not show that the current SwipeSimple account flows through NMI or expose its cash or invoice records. NAB/IRIS documentation offers another processor reporting surface [S19]. Existing Rupert investigations are tracked separately [R1–R3]; their implementation and account-access status should be checked at the relevant release, rather than inferred from this research document.

Do not rotate a shared Authorize.net Transaction Key simply to obtain reporting access. Existing checkout consumers may depend on it; the separate safety guidance records this risk [R3]. Prefer an approved reporting credential arrangement with the narrowest available scope. Read-only code does not imply that the credential itself cannot authorize writes.

## Data contract and known gaps

The exact native formats and import workflow are in [the reporting runbook](swipesimple-reporting.md). The older [prepared line-item importer](swipesimple-import.md) is a separate workflow. Native source snapshots do not create canonical orders, ledger entries, inventory movements or inferred item lines.

| Required evidence | Available from the verified native files | Remaining issue |
| --- | --- | --- |
| Sales / refunds | Separate Sale/Refund rows, processed amount, time, result and tender evidence | No exported original-sale/refund relationship. Supplied files do not prove every lifecycle case occurred. |
| Payment status | Source result preserved; only Approved counts in recorded payment totals | Approval is not settlement. Errored/Canceled can have uncertain processor outcomes [S3]. Later observations may change earlier totals. |
| Cash / card / tips | Cash and recognized card evidence; unknown remains unknown; tips retained when present | Invoice/Payment Link entry method alone does not prove card. Missing tips are not zero; tips already included in processed amount are not added twice. |
| Invoice state | Full snapshot with amounts, dates and source statuses, including manually marked paid | Manual paid status cannot prove collection time/tender. Observed repeated invoice numbers preclude treating the display number as unique identity. |
| Source IDs and documents | Displayed numbers/references, source file/row, hash, capture time, encrypted exact CSV | Opaque portal IDs, invoice documents, receipt history and refund links are not in these exports. No fabricated URL or join. |
| Fees, tax, discounts, item lines | Not established in the implemented transaction/invoice contract | Evaluate actual Sales Report exports or an approved richer feed separately. Processing fees/deposits need processor reconciliation. |
| Freshness and completeness | Receipt/import times and source event observations | Export-generation time and full coverage are not encoded in the files. Operator/producer context is an assertion; browser download completion was the recorded capture-time basis for initial files. |
| ACH returns / settlement | General documentation only, not an account-specific native ACH export contract | Obtain real approved evidence before promising ACH classification, returns or bank reconciliation. |

### ACH changes the completeness assumption

ACH is offered only for enabled merchant accounts. Official guidance says an invoice may show paid before funds settle, status is checked nightly and a failed ACH payment can reopen the invoice. ACH is omitted from Batch/Daily Transaction Reports; detailed returns reporting is available through the Nuvei portal with provider-managed access [S7].

Payment Link guidance identifies ACH in **Paid By**, while **Method** remains Payment Link; returned ACH is marked Declined. Last 4 can describe a bank account rather than a card [S8]. The verified CSV contract has no Paid By column. Rupert therefore must not infer card from that method or last-four value. Unknown tender is an intentional evidence limit, not verified ACH. A new export column/status must be reviewed, rather than silently discarded to pass validation.

Current documentation also disagrees on some operational timing: the ACH invoice FAQ contains different void-window wording within the same article, and general invoice/refund guidance differs from the QuickBooks invoice-matching reopen description [S4, S7, S14]. We did not test money-moving actions to resolve these differences. Preserve observed source states and ask the vendor for account-specific lifecycle semantics. Neither the importer nor this proposal initiates voids/refunds.

### Identity and reconciliation rules

Transaction evidence is scoped by tenant, account, currency, displayed number and Sale/Refund type; immutable observations preserve later changes. Invoice rows are retained inside whole-account full snapshots because invoice numbers repeat. File-row identity is evidence provenance, not a stable vendor invoice ID. A future API must document stable internal IDs, update/delete/void semantics and original-sale links before replacing these rules.

Keep operational sales, gateway authorizations/settlement, processor deposits and invoices as separate sources. Link only on verified identifiers or reviewed matching evidence. Do not add invoice face values to collected payments, sum overlapping source windows, assume a processor deposit includes cash, or count a QuickBooks copy as a second sale. C-Trax stock remains independent of this payment reconciliation work.

## Contract required before unattended hourly intake

Request the following through the existing merchant support relationship; this is a questionnaire, not a sent message or claim that every feature exists:

1. **Entitlement and ownership:** Does this account support a reporting API, sponsored partner access or automatic export delivery? Which legal/vendor product owns the endpoint/feed? Who approves Rupert's use, and are there additional charges or partner requirements?
2. **Coverage:** All devices/users/accounts, cash, card and ACH; invoices and manual-paid states; sales, declines, voids, refunds, returns, disputes, fees and tips. Identify exclusions and which processor feed supplies them.
3. **Identifiers:** Stable internal transaction/invoice/refund IDs, original-sale links, account/device IDs, invoice references and original-document references. Explain nonunique display numbers and IDs across migrated accounts.
4. **Lifecycle:** Creation/event/updated/settled timestamps, source time zone and DST rules, currency/precision, partial refunds, failed/returned ACH, voided refunds, invoice reopen/delete semantics and correction/version behavior.
5. **Delivery:** Actual unattended cadence and latency; API polling/webhooks versus SFTP or another approved file channel; retry/backfill/replay policy, export-generation timestamp, file naming, completion signal, checksum and authenticity mechanism. A SHA-256 alone is not sender authentication.
6. **Completeness:** Pagination, row limits, rate limits, retention, historical windows, late-arriving corrections, full versus incremental invoice snapshots, tombstones and a coverage watermark. Can older changed transactions be retrieved reliably?
7. **Security:** Dedicated least-privilege integration identity, available read scopes, MFA/service-account policy, token expiry/rotation/revocation, TLS, IP restrictions if supported, audit logs and secure credential provisioning. Do not email portal passwords or put secrets in sample files.
8. **Proof:** Documentation plus a private redacted schema/sample for each feed; an approved test method using existing transactions; independent period totals to reconcile and the support escalation contact.

Once a contract exists, implement the producer against the documented interface, with bounded requests/files, sanitized errors, full pagination, overlapping correction windows and atomic replay-safe receipts. Keep vendor acquisition separate from the existing local importer. Do not put credentials in inbox manifests. Unexpected schemas, missing pages or incomplete invoice snapshots must fail visibly without replacing good evidence.

Before enabling intake on SER8, validate at least two independently delivered files/polls with advancing **source** timestamps, compare counts and each tender/tip/refund component against the same vendor range, test retries and late corrections, and verify stale-feed alerting. Maintain independent backfill coverage and processor/bank reconciliation. No automatic setting change follows from this document or roadmap entry.

## Follow-up work and acceptance

| Priority | Work | Completion evidence |
| --- | --- | --- |
| Next | Valmar confirms approved SwipeSimple feed or explicitly states none is offered | Account-specific written access/delivery contract; no credential in public issue. |
| Next | Preserve long-term Valmar / Authorize.net direction in Rupert | Planned roadmap objective F64; supported source roles and authorization boundaries documented here. |
| After vendor reply | Obtain actual Sales Report / batch / ACH formats if relevant | Private original files and sanitized fixtures with verified schemas; no invented compatibility claim. |
| After supported access | Add vendor producer or approved API adapter | Real read diagnostic, lifecycle/coverage tests, secure secret setup and advancing source freshness. |
| Before cross-source totals | Define gateway/processor/account mapping and matching | Verified native ID relationships; duplicates/overlaps visible; cash, fees and settlement handled separately. |
| Before hourly activation | Production reconciliation and recovery check | At least two deliveries, replay/correction/failure checks, freshness monitoring; explicit operator enablement. |

The current choice remains manual native CSV intake plus disabled automation. If the provider cannot supply a supported hourly feed, document that vendor limitation and keep manual imports; do not describe periodic re-import of an unchanged file as syncing.

## Primary source register

All sources below were reviewed during October 15–16, 2026. Dates are vendor article update dates when displayed, not guarantees about feature rollout or account eligibility. The summaries above are paraphrases; no vendor documentation or private merchant response is copied wholesale.

| Ref | Primary source | Evidence / date |
| --- | --- | --- |
| S1 | [SwipeSimple public API statement](https://support.swipesimple.com/hc/en-us/articles/27117544574487-Does-SwipeSimple-have-a-public-API-for-integrations) | June 26, 2026; no public API. |
| S2 | [Export transactions](https://support.swipesimple.com/hc/en-us/articles/360011804593-How-do-I-export-my-transactions) | July 24, 2026; CSV, limits, filters and omitted detail. |
| S3 | [Transaction history](https://support.swipesimple.com/hc/en-us/articles/9486490445719-Transaction-History-in-SwipeSimple-Dashboard) | August 4, 2026; history scope, results, methods, detail/receipt views. |
| S4 | [Invoices on web](https://support.swipesimple.com/hc/en-us/articles/360019039554-Invoices-on-Web-How-To-Guide) | July 28, 2026; CSV and invoice lifecycle. |
| S5 | [Batch and daily reports](https://support.swipesimple.com/hc/en-us/articles/360011707534-Batch-Reports-Daily-Transaction-Reports) | August 24, 2026; processor-dependent cadence, recipients and exports. |
| S6 | [Sales Report](https://support.swipesimple.com/hc/en-us/articles/9485797383703-Sales-Report) | April 14, 2025; aggregate dimensions and manual CSV. Newer ACH guidance adds a column absent from this older article. |
| S7 | [ACH invoice FAQ](https://support.swipesimple.com/hc/en-us/articles/41092562723863-ACH-on-Invoices-FAQ) | September 17, 2026; settlement/returns, Nuvei reporting and batch-report exclusion. |
| S8 | [ACH Payment Links](https://support.swipesimple.com/hc/en-us/articles/42552477121815-ACH-for-Payment-Links) | September 17, 2026; Paid By, Method, returns and reporting. |
| S9 | [SwipeSimple terms of service](https://home.swipesimple.com/legals/terms-of-service) | October 6, 2026; account security and section 11(d) restrictions on crawling/scraping. Account agreements may add terms. |
| S10 | [Reseller program](https://home.swipesimple.com/resellers), [Partner Content Hub](https://home.swipesimple.com/content-hub) | Current partner routes/resources; no merchant reporting API specification found there. |
| S11 | [QuickBooks marketplace listing](https://home.swipesimple.com/app-marketplace/quickbooks-online-sync) | On-demand positioning and advertised price at review time. |
| S12 | [QuickBooks FAQ](https://support.swipesimple.com/hc/en-us/articles/39071649541527-QuickBooks-Online-Sync-FAQ) | July 27, 2026; provider eligibility, forward-only history and accounting mappings. |
| S13 | [QuickBooks reconciliation](https://support.swipesimple.com/hc/en-us/articles/42267993080215-How-to-reconcile-in-QuickBooks-Online-after-syncing-SwipeSimple) | July 27, 2026; manual sync and separate bank matching. |
| S14 | [QuickBooks invoice matching](https://support.swipesimple.com/hc/en-us/articles/40269780462999-QuickBooks-Online-Sync-Invoice-Matching) | May 6, 2026; invoice modes, immediate versus manually synced operations, refund/void behavior. |
| S15 | [Appointments integrations](https://support.swipesimple.com/hc/en-us/articles/30808263357847-SwipeSimple-Appointments-Integrations) | August 4, 2026; scheduling-specific API and Zapier. |
| S16 | [Valmar knowledge base](https://vlmr.com/knowledge-base/) | Separate gateway/processor portals and support routes. |
| S17 | [Authorize.net transaction reporting](https://developer.authorize.net/api/reference/features/transaction-reporting.html) | Supported transaction/batch reporting methods. |
| S18 | [NMI Query API](https://docs.nmi.com/reference/query) | Separate documented gateway reporting interface; account scope remains to be established. |
| S19 | [NAB IRIS API](https://nabankco.iriscrm.com/api), [tenant OpenAPI specification](https://nabankco.iriscrm.com/api/v1.yaml) | Separate processor-reporting contract investigated in R2; not SwipeSimple API entitlement. |
| S20 | [CardFlight SDK history](https://www.cardflight.com/blog/six-years-of-growth) | Historical retrospective about payment-acceptance SDK and cessation of new integrations at that time. |
| S21 | [Intuit webhook configuration](https://static.developer.intuit.com/output_html/qbo/docs/develop/webhooks/configure-webhooks.html) | OAuth-authorized accounting-company notifications and signature verification. This does not automate upstream SwipeSimple sync. |

Repository evidence: [R1: Authorize.net reporting PR #43](https://github.com/techmore/rupert/pull/43), [R2: IRIS reporting PR #49](https://github.com/techmore/rupert/pull/49), [R3: shared gateway-key safety PR #50](https://github.com/techmore/rupert/pull/50). These are separate workstreams; an open PR, a passing fixture test and an account-authorized live feed are different evidence levels.
