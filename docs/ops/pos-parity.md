# POS parity requirements and acceptance

Reviewed 2026-10-15. Requirements come from the business's POS comparison
supplied on 2026-10-12 and its associated planning conversation. This document
contains a sanitized requirements summary; private conversations, attachments,
contact details and account credentials are not published.

## Implemented release scope

The application now includes an image-based Shopify catalog cart and server-priced quote with no-tip, percentage and custom tip choices. It does not complete a sale, calculate tax, collect a tip or charge a terminal. The existing POS remains the place to complete payments.

Remote clock-in/out is tied to an active worker record linked to the signed-in account. Workers request corrections from any authorized device; payroll reviewers approve or reject them with the original/requested timestamps retained. The 1% commission screen is a read-only estimate that gives each overlapping person the full percentage. It uses the imported order occurrence timestamp (some connectors use order creation time), a selected source/currency and a disclosed pre-discount item-price basis. It excludes incomplete payment coverage, recorded refunds and invalid item pricing. It does not finalize compensation or payouts.

Daily register summaries use separate order, payment and refund event dates, preserve source/location/currency groups, and export CSV. Tender/refund/net detail, missing/incomplete/excess/unknown payment coverage and source-specific import freshness are visible. Shopify tenders and their payment dates remain inferred; unsettled orders are excluded. Discounts, collected tips, merchant fees, C-Trax imports and terminal/bank reconciliation remain incomplete; unavailable values are not reported as zero. Gift/store-credit activity means tenders less refunds is not settled bank cash. The [reviewed sales import guide](https://techmore.github.io/rupert/sales-imports.html) documents the validated prepared SwipeSimple line-item CSV contract and its limits.

The role presets cover cashier/POS, inventory employee, reporting and admin. Store admins can assign store roles; super-admin access remains protected. New accounts without an explicit role default to cashier. Deactivated browser sessions are rejected. The API guide documents scoped, revocable read access; it is separate from payment-provider or terminal integration.

Provider account preparation, explicit KORONA/Cova read checks and selected Valmar Authorize.net/NMI credential/profile checks are documented in the [connection guide](https://techmore.github.io/rupert/payment-integrations.html). Read-access verification does not establish checkout readiness.

Exact Shopify source order/line/variant identities now support immutable gram recipe versions and reviewed one-time deductions against an actual bulk lot, with shortage/replay checks and receipt CSV. A bounded read-only inventory review queue surfaces stored stock, hold and identity issues. Manual catalog links and explicit unlinks survive sync; ambiguous automatic matches remain unresolved. See the [inventory workflow guide](https://techmore.github.io/rupert/inventory-workflows.html) for operator steps, legacy mirror/count limits and remaining automatic Sheets/refund work.

Valmar is the business-reported payment-services provider; the account's gateway, backend processor and acquiring bank require confirmation. Authorize.net is a possible gateway. Rupert's setup checks do not authorize, capture or refund payments. A separate legacy Authorize.net warehouse-checkout code path exists, but live account, terminal and settlement acceptance remains unverified. See [Payments in plain English](https://techmore.github.io/rupert/payment-basics.html) for the roles and official contact details.

## Primary POS cutover gate

Before replacing the current POS, demonstrate the selected merchant account/gateway and supported terminal, customer-facing tipping, taxes and discounts, failed/retried payments, refunds/tip reversals, loyalty and gift tenders, and daily source-to-bank reconciliation. The operator team must validate real checkout and register-close scenarios, retain a tested fallback, and approve cutover. A quote preview or vendor marketing page does not establish primary POS readiness.

## Required operator workflows

| Requirement | Rupert baseline | Release acceptance |
| --- | --- | --- |
| Remote/home clock-in and clock-out | Manual timesheets exist; a remote punch workflow is separate work. | An authenticated worker records their own shift from an authorized device. Only one shift can remain open. Repeated requests are safe, time boundaries are explicit, and workers cannot change another worker's time. |
| Corrections from home | Existing timesheet editing does not establish punch corrections. | Worker submits old/new times and a reason. A permitted reviewer approves or rejects; the original values, request, reviewer and result remain auditable. No silent overwrite. |
| 1% for each worker during their shift | Manual commission/payroll entries do not implement sales-to-shift allocation. | Every eligible paid sale is matched to each worker's interval, including overlapping workers. The 1% amount is calculated independently for each person, with no shared-pool division. Currency, eligible sales basis, interval boundaries, refunds and rounding are visible and tested. |
| Customer tipping | Source POS systems may collect tips; Rupert has no native payment tip prompt. | Customer sees clear presets, custom amount and no-tip choice. Tips are separated from merchandise/tax in records and reports; failed/retried payments and refunds cannot duplicate or lose tip money. Selected processor/hardware must pass a sandbox demonstration before live collection. |
| Daily cash/card register summaries | Local sessions summarize mirrored cash/card/gift payments and count variance. | Business-day and register/location filters reconcile to the source. Cash, card, tips, refunds, adjustments and other tenders are explicit; cutoffs, missing imports and stale source data are visible. |
| Contractor participation | Worker records and payroll calculations exist. | Eligible contractors can be linked to sign-in accounts, record their own shifts and appear in permissioned commission previews. This does not automatically enroll them in payroll or send payouts. |

Example overlap acceptance: worker A is present 09:00–12:00 and B
10:00–11:00. Two eligible sales of 100 currency units at 09:30 and 10:30
produce an estimate of 2 units for A and 1 for B. The overlapping sale gives
each worker 1 unit; it does not split 1 unit between them. An order at clock-out
belongs outside a half-open interval `[clock_in, clock_out)`.

The first commission implementation must be labeled a preview. It must state
its selected merchandise-only basis and source/currency filters, exclude
unpaid or voided orders, and disclose unhandled refunds or adjustments. It
must not finalize payroll, change approved timesheets or initiate payments.
Approved time corrections must recompute the preview. Rules for the final
payroll amount require a versioned, approved compensation policy.

## Vendor evidence

KORONA documents terminal time tracking and general cashier/team commission
configuration. Those do not establish remote employee punches or this exact
overlap formula. Its manual documents tipping setup and register business-day
closeouts. [Time tracking](https://manual.koronapos.com/working-times/),
[commission setup](https://manual.koronapos.com/setting-up-commission/),
[tipping](https://manual.koronapos.com/tipping/),
[end-of-day statements](https://manual.koronapos.com/finish-day-end-of-day-statement/).

Cova advertises daily/closeout analytics, Cova Pay tipping and a KayaPush
workforce integration. KayaPush describes mobile attendance; the exact
per-person overlap commission and a specific daily per-register cash/card
report require demonstration. [Reporting](https://www.covasoftware.com/cannabis-analytics-reporting),
[US tipping/payments](https://www.covasoftware.com/cannabis-payments-for-dispensaries),
[workforce companion](https://www.covasoftware.com/cannabis-pos-payroll-hr),
[partner attendance](https://www.kayapush.com/comparison/kayapush-vs-adp).

C-Trax advertises tipping, retail analytics, access roles, multi-location
operation and PAX device integration. Its exact shift/commission and tender
report behavior require verification; the public page contains some incomplete
integration descriptions. No particular terminal support cutoff is asserted
here. [Official product overview](https://c-trax.com/).

SwipeSimple documents tip settings and daily/batch reporting with cash/card
details. Batch closing and daily report cutoffs vary by merchant provider;
neither report alone proves a deposit reconciliation. [Tip settings](https://support.swipesimple.com/hc/en-us/articles/9479964055063-Account-Settings),
[daily and batch reports](https://support.swipesimple.com/hc/en-us/articles/360011707534-Batch-Reports-Daily-Transaction-Reports).

Valmar and Easyteam are integration candidates rather than ERP competitors.
Valmar describes gateway/payment and reconciliation tools; merchant approval,
supported products, gateway path and terminal compatibility remain account
specific. Easyteam documents remote punches and generic commissions, while its
default sales attribution is to a single staff member; the required overlap
formula is not established. [Valmar](https://vlmr.com/merchant-services/),
[Easyteam features](https://help.easyteam.io/en/article/easyteam-pricing-plans-and-billing-1p4sbaa/),
[Easyteam attribution](https://help.easyteam.io/en/article/how-to-attribute-a-sale-to-a-staff-member-usbxrb/).

The business has an October replacement decision target. Vendor support
dates, merchant account approvals and readiness for a particular processor
must be verified directly; roadmap entries and marketing claims do not
establish those facts.

## Remaining implementation sequence

Reviewed line-item CSV inputs and source-aware register coverage are implemented. Exact source line/variant identities, immutable gram recipes, reviewed local sale deductions and bounded inventory exception review are also implemented. Automatic material/refund reconciliation and Google Sheets updates remain pending a selected destination and reconciliation contract; split-lot and multi-material recipes remain separate work. C-Trax/native terminal and deposit ingestion still require a verified account contract. Actual checkout, taxes/discounts, tip collection, supported terminal execution and payment/refund/settlement round trips remain the primary-POS cutover gate. Existing POS operation remains required until operator acceptance passes.
