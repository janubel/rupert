# POS parity requirements and acceptance

Implementation scope reviewed October 17, 2026 against repository source `19d0c2c`. Requirements come from the business's POS comparison
supplied on 2026-10-12 and its associated planning conversation. This document
contains a sanitized requirements summary; private conversations, attachments,
contact details and account credentials are not published.

## Implemented release scope

The legacy Shopify catalog cart remains a quote workflow. The separate **Retail POS** uses native C-Trax variants with mirrored website images, source prices and per-item store tax assignments. Its paired customer display offers private no-tip, percentage and custom tips with explicit confirmation. Real cash checkout records a paid receipt, tender/change, tip and register totals atomically, with duplicate-safe submission and an optional durable C-Trax stock outbox. Missing tax data blocks checkout; price/tax/cart changes require another confirmation. Local allocation prevents overlapping Rupert cashiers from using the same stock, but cannot reserve it against independent C-Trax sales. See [retail operation and limits](https://github.com/techmore/rupert/blob/main/docs/ctrax-retail.md).

Optional Authorize.net AcceptUI checkout collects a one-use token on the customer display and verifies gateway identity, captured transaction status, invoice and exact server total before completing a sale. Durable attempts and read-only recovery handle uncertain outcomes without blind charge retries. NMI has a separate sandbox-only implementation: test receipts create no live sales, register revenue or stock effects, and production charging is blocked. Vendor-connected sandbox/live acceptance remains unverified. No PAX terminal execution, gateway refund/void, split tender, checkout discount or variable-price flow is implemented.

Remote clock-in/out is tied to an active worker record linked to the signed-in account. Workers request corrections from any authorized device; payroll reviewers approve or reject them with the original/requested timestamps retained. The 1% commission screen is a read-only estimate that gives each overlapping person the full percentage. It uses the imported order occurrence timestamp (some connectors use order creation time), a selected source/currency and a disclosed pre-discount item-price basis. It excludes incomplete payment coverage, recorded refunds and invalid item pricing. It does not finalize compensation or payouts.

Canonical daily register summaries use separate order, payment and refund event dates, preserve source/location/currency groups, and export CSV. Tender/refund/net detail, payment coverage diagnostics and source-specific import freshness are visible; Shopify tenders/payment dates remain inferred. Native C-Trax daily imports separately retain order, tax, discount, tip, tender and refund controls, with independent report comparisons and local review. Cash variance remains Unknown for incomplete/open/cross-day source sessions or unverified drawer movements. Rupert checkout receipts and physical register counts are separate from native source-register closing. Merchant fees, payment-to-order links, payouts and actual bank funding remain incomplete; unavailable values are not zero. Gift/store-credit and tips also prevent treating tenders less refunds as settled bank cash. See [sales import limits](https://techmore.github.io/rupert/sales-imports.html), [source reconciliation](https://github.com/techmore/rupert/blob/main/docs/ops/money-reconciliation.md) and [financial close](https://github.com/techmore/rupert/blob/main/docs/ops/financial-close.md).

The role presets cover cashier/POS, inventory employee, reporting and admin. Store admins can assign store roles; super-admin access remains protected. New accounts without an explicit role default to cashier. Deactivated browser sessions are rejected. The API guide documents scoped, revocable read access; it is separate from payment-provider or terminal integration.

Provider account preparation, explicit KORONA/Cova read checks and selected Valmar Authorize.net/NMI credential/profile checks are documented in the [connection guide](https://techmore.github.io/rupert/payment-integrations.html). Read-access verification does not establish checkout readiness.

Exact Shopify source order/line/variant identities now support immutable gram recipe versions and reviewed one-time deductions against an actual bulk lot, with shortage/replay checks and receipt CSV. A bounded read-only inventory review queue surfaces stored stock, hold and identity issues. Manual catalog links and explicit unlinks survive sync; ambiguous automatic matches remain unresolved. See the [inventory workflow guide](https://techmore.github.io/rupert/inventory-workflows.html) for operator steps, legacy mirror/count limits and remaining automatic Sheets/refund work.

Valmar is the business-reported payment-services provider; the account's gateway, backend processor and acquiring bank require confirmation. Authorize.net is a possible gateway; implemented checkout support does not establish its assignment to this store. Preparation/read checks cannot charge or refund payments. Per-store Authorize.net checkout is a separate configuration from reporting and the legacy warehouse checkout. Deep Run Hemp's historical WooCommerce/NMI sale is separate merchant evidence, not approval to route Herbal Healers payments or proof of Rupert acceptance. Current account, terminal and settlement acceptance remain unverified. See [Payments in plain English](https://techmore.github.io/rupert/payment-basics.html) for the roles and official contact details.

## Primary POS cutover gate

Before replacing the current POS:

1. Confirm the intended merchant/account, approved products, gateway, checkout domain/channel and any required terminal contract. Do not substitute another business’s historical account.
2. Complete vendor-connected sandbox scenarios for exact tax/tip totals, approvals/declines, stale cart confirmation, duplicate/concurrent submits and lost-response recovery. NMI additionally needs dedicated test credentials; production requires a separately reviewed implementation. A demo or fixture test is not vendor acceptance.
3. Implement and accept each required discount, variable-price, split/gift/loyalty tender, refund/void and tip-reversal workflow. A local refund record does not return gateway funds or restock source inventory. Demonstrate an approved PAX integration if card-present operation is required.
4. Verify a representative sale/day and later refund across receipt/register, source stock effects, gateway batch, processor fees/payout and actual bank evidence. Local close packages and matching report totals alone do not prove settlement.
5. Train staff, test the existing checkout fallback and obtain explicit operator/owner cutover approval after controlled live acceptance. This documentation review executes no payment, source stock write or live test.

## Required operator workflows

| Requirement | Current implementation | Remaining acceptance |
| --- | --- | --- |
| Remote/home clock-in and clock-out | Authenticated worker clock-in/out is linked to an active employee record, with a single-open-shift boundary. | An authenticated worker records their own shift from an authorized device. Only one shift can remain open. Repeated requests are safe, time boundaries are explicit, and workers cannot change another worker's time. |
| Corrections from home | Worker requests and permitted reviewer approval/rejection preserve original/requested times and outcomes. | Worker submits old/new times and a reason. A permitted reviewer approves or rejects; the original values, request, reviewer and result remain auditable. No silent overwrite. |
| 1% for each worker during their shift | A selected-source/currency preview estimates the full percentage independently for each overlapping worker. Final compensation policy and payouts remain separate. | Every eligible paid sale is matched to each worker's interval, including overlapping workers. The 1% amount is calculated independently for each person, with no shared-pool division. Currency, eligible sales basis, interval boundaries, refunds and rounding are visible and tested. |
| Customer tipping | Private paired-screen confirmation, cash receipt tips and conditional hosted-card support are implemented. NMI receipts are sandbox-only. | Customer sees clear presets, custom amount and no-tip choice. Tips are separated from merchandise/tax in records and reports; failed/retried payments and refunds cannot duplicate or lose tip money. Selected processor/hardware must pass a sandbox demonstration before live collection. |
| Daily cash/card register summaries | Canonical event-dated summaries, Rupert registers/physical counts and separate native C-Trax day/report controls are implemented. | Business-day and register/location filters reconcile to the source. Cash, card, tips, refunds, adjustments and other tenders are explicit; cutoffs, missing imports and stale source data are visible. |
| Contractor participation | Worker records and payroll calculations exist. | Eligible contractors can be linked to sign-in accounts, record their own shifts and appear in permissioned commission previews. This does not automatically enroll them in payroll or send payouts. |

Example overlap acceptance: worker A is present 09:00–12:00 and B
10:00–11:00. Two eligible sales of 100 currency units at 09:30 and 10:30
produce an estimate of 2 units for A and 1 for B. The overlapping sale gives
each worker 1 unit; it does not split 1 unit between them. An order at clock-out
belongs outside a half-open interval `[clock_in, clock_out)`.

The commission implementation remains labeled a preview. It must state
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

Cash checkout, confirmed customer tips, source-derived taxes, optional Authorize.net hosted-card capture/recovery, NMI sandbox checkout and native C-Trax daily imports are implemented within the limits above. Native NAB Daily Deposits and source summaries provide separate reporting evidence, not bank settlement proof. First complete the approved merchant/account and vendor-connected acceptance gates rather than rebuilding these implemented paths. Then finish the required refunds/voids, discounts/tenders and terminal integration, prove source-to-bank reconciliation and obtain operator cutover approval.

Exact source line/variant identities, immutable gram recipes, reviewed local lot deductions and bounded inventory exception review are implemented. Automatic material/refund reconciliation and Google Sheets updates remain pending a selected destination and reconciliation contract; split-lot and multi-material recipes remain separate work. Paid retail variant deductions do not automatically consume bulk recipes or reverse refunds. Continue the existing POS/fallback alongside Rupert until the applicable daily-use gates pass. The [pickup plan](https://github.com/techmore/rupert/blob/main/docs/ops/day-to-day-readiness.md) records priorities and acceptance evidence to collect.
