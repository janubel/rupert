# Derrick's day-to-day rollout and pickup plan

Reviewed October 15, 2026 (America/New_York), against deployed application release `032dc062ca796ecd997f07cc6cefedf4556f9fe0` ([PR #31](https://github.com/techmore/rupert/pull/31)). This is a readiness assessment, not a merchant-account certification or operator signoff. No real payment/terminal acceptance was completed in this work.

## Where we stopped

Rupert can be piloted beside the existing POS for daily review and local records. It is **not ready to replace the checkout or become the sole stock authority**. Keep completing payments and confirming stock in the current systems while the gates below are open.

The deployed release has compact navigation, seven role presets, protected personnel/payroll views, private owner checklists, private workspace review and a platform dashboard. The release passed 789 tests on both SQLite and PostgreSQL (two SQLite-specific skips on PostgreSQL), production health/integrity checks and restore verification of a private SQLite backup. GitHub Pages has 63 catalogued features; an Available label describes its documented scope, not full POS readiness.

| Use now, with operator review | Do not rely on yet |
| --- | --- |
| Sales/dashboard review, source-aware daily register CSV, local cash-session records | Verified processor settlement, bank deposits, complete tip/fee/discount reporting |
| Inventory review, manual catalog links, SKU scan-to-count and approval records | Complete native stock coverage or automatic application of approved counts |
| Bulk lot ledger, exact Shopify-variant gram recipes and reviewed one-time sale deductions | Automatic deductions/refund restocking, multi-material or split-lot consumption |
| Source/location-specific local holds, release and expiry | Holds enforced in external sales channels or automatic fulfillment allocation |
| Worker clock/corrections and overlapping-shift commission estimates | Final commission policy, automated payroll posting or payouts |
| Encrypted provider setup and selected credential/read checks; scoped read API | Payment capture, terminal execution or automatic C-Trax/KORONA/Cova business-data ingestion |

## Payments: blockers before replacing the POS

| Priority and next action | Owner | Done when |
| --- | --- | --- |
| P0 — Confirm the existing merchant arrangement with Valmar: gateway (Authorize.net, NMI or another), backend processor/acquirer, approved products and channels, account environment and PAX model/payment application. | Business owner + Valmar/provider | Account-specific confirmation identifies the supported gateway and terminal integration. Do not assume Authorize.net is already this account's gateway. |
| P0 — Obtain approved developer/test access, record the setup privately and run the applicable explicit credential check. | Business owner + implementer | Correct test credentials and vendor integration contract are available; the narrowly scoped check succeeds. Credentials stay out of Git and chat. |
| P1 — Build the chosen checkout and supported terminal path: server-calculated tax/discounts, customer tip choice, completed-sale/receipt records, authorization/capture, decline/cancel/timeout handling and duplicate-safe retry/recovery. | Implementer | Vendor sandbox/test-terminal scenarios prove exactly one sale/charge, correct totals and a recoverable result after interrupted requests. The current cart/tip screen is only a quote. |
| P1 — Complete void/refund/tip reversal and tender handling, including gift/store credit, cash/card and any required split tender. | Implementer + operator | Each required scenario reconciles the source sale, payment and refund without duplicated money or misleading stock changes. A local refund record alone does not return money. |
| P1 — Import the actual daily POS/payment data and reconcile register → gateway/processor batch → fees/payout → bank deposit. | Implementer + operator/bookkeeper | A representative trading day and later refund agree across records, with explicit timing/currency/location differences and missing-data warnings. Current summaries are not bank settlement proof. |
| Cutover — Train staff, test the fallback and conduct explicitly approved controlled live acceptance. | Business owner + operator | Written acceptance covers sale, tipping, tax/discount, failure/retry, refund and closeout; fallback works. Only then replace the current checkout. |

Valmar is the business-reported payment-services provider. Rupert currently has selected Authorize.net/NMI **credential/profile checks**, not a completed payment platform. A separate legacy Authorize.net warehouse checkout exists; it does not establish retail terminal or settlement readiness. Saving POS credentials does not configure that legacy checkout.

C-Trax needs its account-specific API/export contract and real samples before an adapter can be built. SwipeSimple has a reviewed prepared line-item CSV import; native reports may need conversion, and refunds, split tenders, tax/tips/fees and direct API access are outside that import. KORONA/Cova credential read checks do not import catalog or sales. Choose the system Derrick will actually use before building every candidate adapter.

Provider contacts and setup details: [payments explained](payment-basics.md), [payment connections](payment-integrations.md), [POS acceptance](pos-parity.md), [sales import contract](swipesimple-import.md). Store account references, contacts, renewals and test evidence in Rupert's authenticated [owner checklist](owner-checklists.md), not this public repository.

## Inventory: first pilot, then reliable stock control

1. **Verify the starting data.** Confirm which stores and locations are actually active; Square's historical presence does not prove it is today's POS. Compare representative high-turn items in Rupert with each native source and physically counted stock. Check import freshness, duplicate SKUs, exact item/location IDs and manual links. Shopify and Square are independent pools; never equalize their counts merely because they differ. The review queue is bounded and is not a full audit.
2. **Fix native coverage and count precision before stock authority.** Engineering must preserve real per-location quantities and provenance, negative/unknown states and complete fetch coverage. Current Shopify clamping, aggregate fallback and fetch caps can hide problems. Count preparation/comparison must use an exact source/item/location pool rather than ambiguous SKU or multi-location sums. Define reviewed correction/application and reconciliation separately: approving a worksheet currently changes audit records, not platform stock. Any Shopify/Square mutation or SKU change requires explicit owner signoff under `AGENTS.md`.
3. **Pilot physical counting with the inventory role.** Use a small agreed item set, scan an exact stored SKU, enter the physically counted total, submit and review the worksheet. Prepared quantities are already filled in; adding scans can overcount unless the starting value is handled deliberately. Test unknown/duplicate codes and retry behavior. Barcode import is still missing; SKU scanning is the immediate supported path. Labels, scan-to-receive, camera and offline work remain separate features.
4. **Pilot bulk grams against real lots.** Enter verified opening lot balances and exact Shopify-variant recipes/effective dates. Review one complete paid source sale, choose the actual lot, preview and record the deduction. Verify grams, remaining balance and receipt; prove replay/shortage protection. Current support is one material and one lot per whole sale line. Refunded/changed orders require reviewed corrections; refunds never automatically restock raw material.
5. **Define the remaining automation contract.** Agree when a sale consumes material, how edited/cancelled/refunded sales and waste are reconciled, how lines split across lots/materials, and which Google Sheet (if any) is authoritative. Build and test replay-safe reconciliation only after these decisions. Existing movement/receipt CSV exports are manual export, not Sheets synchronization.
6. **Use holds as local advice.** Demonstrate exact-pool hold/release/expiry and check overcommitment after imports. External sales can still consume the same stock. Transfers, backorders, channel-enforced reservations and automatic fulfillment consumption remain unfinished.

Pilot acceptance: Derrick and the inventory operator can explain an item's source/location balance, reproduce a physical count, resolve a catalog ambiguity and trace a bulk deduction to its source sale, lot and recipe. Keep discrepancy evidence in the private checklist. Expand only after the sample reconciles; do not label every mirrored quantity trustworthy from an empty exception queue.

Detailed limits and operator steps: [inventory workflows](inventory-workflows.md). Roadmap areas: F09–F13, F33–F35, F50 and F59.

## Daily routine during the pilot

- Morning: check source freshness, inventory exceptions, duplicate/unresolved identities, active holds and low bulk balances; verify questionable quantities in the source/physical stock.
- During the day: take payment in the existing POS; use Rupert for reviewed counts, local holds and selected-lot material records within the limits above.
- Close: compare the source's sales/tender/refund totals with Rupert's register report, note missing coverage and separately confirm actual processor/bank settlement. Review material-use audit flags and record corrections with references.
- Staff: assign the minimum role, link active workers before clock use, and agree who reviews counts/time corrections. The 1% overlap calculation remains an estimate until its sales basis, refund rules, rounding and compensation policy are approved.

## Operations and next pickup

Keep SQLite/WAL in the SER8 Incus instance and the single-worker default. There is no demonstrated need to change the database for this pilot. Consistent local backup/restore and Incus recovery points were verified; verify off-host recovery of the database **and encryption/configuration keys** before business-critical reliance. Instance Drive backups require platform configuration; legacy workspace destinations are ignored. Review the pre-existing failed queue job and monitor scheduled import failures/freshness without triggering jobs just to test a screen.

Resume from `main`, inspect current status and the feature catalog, and read `AGENTS.md` before implementing changes. Preserve subsequent business records. A host AppArmor/signal issue has affected ordinary service/container restarts; older dated deployment receipts describe historical procedures and must not be blindly replayed. The latest release used the existing service cgroup activation procedure after a fresh backup, exact-release/clean-checkout checks, confirmation that service processes belonged to Rupert and a zero-claimed-jobs check. Revalidate the host and that procedure before another deployment; do not disable AppArmor, alter unrelated host services or make the container privileged. Do not switch back to the frozen PostgreSQL cutover copy without reconciling later SQLite writes.

**Recommended next slice:** verify the real inventory source/location sample and obtain the Valmar gateway/PAX integration facts in parallel. Then fix exact inventory coverage/count semantics and implement one approved payment path. Leave alternative POS adapters and broader ERP features on the roadmap until these daily-use gates pass. Record each gate's evidence, reviewer and date privately; this plan does not mark them complete.
