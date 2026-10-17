# Derrick’s day-to-day rollout and pickup plan

Reviewed October 17, 2026 (America/New_York). Deployed application checkpoint: `96da470`, including the financial consolidation, preserved operator sign-in preferences and native Shopify count-basis change described below. This supersedes the October 15 assessment: substantial checkout, C-Trax stock, reporting and recovery work has since landed. Implementation, deployment and merchant/operator acceptance are different evidence levels.

## Where we are now

Use Rupert alongside the existing POS for a controlled operational pilot. The current retail stock reference is **C-Trax**; Shopify and C-Trax mostly describe shared physical stock. Square is disabled in this operating model. Never add the two stock observations together or automatically equalize them.

The October 17 [combined-release checkpoint](combined-release-recovery-2026-10-17.md) verified clean production revision `96da4700b2ac3c05ee7b2aaa3f4ae1e23057d019`, active web/jobs and application of both previously pending migrations (`20261017130000` and `20261017190000`). Existing records, encrypted settings, retained originals and newer live controller work were preserved. The fresh post-deployment recovery archive was restored and verified on SER8 and off-host; all eight isolated read-only page checks passed and the deployment lock was released. Deployment does not establish merchant or physical-inventory acceptance. Never replace a newer live revision from an older checkout. No payment, physical count, manual provider read or stock write was performed for this release verification.

| Already implemented | Still needs acceptance or additional work |
| --- | --- |
| Native C-Trax stock, SKU/barcode/native-ID worksheets; complete Shopify catalog reads and signed on-hand/available/committed observations; shared-stock comparison | Physical sample verification, uncertain item/package equivalence, freshness and operational correction policy |
| New Shopify worksheets use exact native on-hand snapshot evidence; submitted historical comparisons remain intact | Reviewed worksheet approval is still audit-only; source stock correction/application is separate |
| Real cash checkout, change, tax checks, private customer tip confirmation, receipts and register effects | Training, cash handling, end-to-end source/stock verification and approved cutover |
| Conditional Authorize.net hosted-card checkout and read-only uncertain-outcome recovery; NMI sandbox-only checkout | Correct merchant account, vendor-connected sandbox proof and explicit live acceptance; NMI production charging stays blocked |
| Native C-Trax daily sales/register reads, SwipeSimple website evidence, Authorize.net reporting/import paths and NAB deposit evidence | Access/entitlement per source, complete-period coverage, refunds/fees/payout/bank matching; overlapping reports are not additive |
| Durable paid-sale C-Trax stock outbox, selected-lot Shopify material deductions and local holds | Native stock-write acceptance, shared-channel concurrency, automatic material/refund reconciliation and source-enforced allocation |
| Scoped staff access, clock corrections, commission preview and private owner checklist | Approved compensation policy/payout workflow and operator signoff |

The catalog’s Available or Partial labels describe their stated scope, not full POS certification. Refer to the per-feature evidence rather than assuming the older quote-only POS is the current retail implementation.

## Inventory: next daily-use gates

1. **Physically verify a small agreed sample.** Select the actual C-Trax store and Shopify location, compare high-turn items and bulk/package variants with source records and shelf counts, and resolve discrepancies privately. Investigated/name-package candidates are suggestions; they withhold numerical differences until equivalence is established. An empty bounded exception queue is not a complete audit.
2. **Use the right quantity for physical counts.** New Shopify worksheets use native signed `on_hand` from the selected location snapshot, with catalog/shop/read-epoch identity checks. Missing, ambiguous, untracked, fractional or stale evidence must remain unavailable, not zero. Existing submitted comparisons keep their original basis and timestamps; legacy available/aggregate values do not become verified on-hand history. C-Trax worksheets retain their native store/variant comparison. Confirm the screen’s source, basis and observation time before interpreting a difference.
3. **Pilot scanner and review discipline.** Load a location sheet, use the exact stored SKU/barcode and enter the physically counted total. Prepared physical inputs already contain observed quantities, with negative observations starting at zero; adding scans without deliberately replacing/clearing the starting amount can overcount. Prove unknown/duplicate code handling and safe request retry. Missing-SKU Shopify rows and broader receiving/label/offline workflows remain separate work.
4. **Define count correction/application.** Approval freezes an audit; it does not change Shopify, Square or C-Trax stock. A later correction flow needs explicit authorization, an exact source item/location, a fresh before-value, concurrent-change handling, duplicate-safe recovery and post-write verification. Shopify/Square mutations and SKU edits require explicit owner signoff under `AGENTS.md`.
5. **Accept real checkout stock effects separately.** Paid Rupert sales can enqueue C-Trax stock removals when enabled. Validate the native removal/history contract and conduct explicitly approved controlled acceptance. A pending/unknown response must be investigated using its durable source marker, never blindly retried. Rupert allocations cannot reserve stock against independent C-Trax or Shopify sales.
6. **Pilot bulk-material records.** Establish verified opening lots and exact Shopify-variant gram recipes/effective dates, then reconcile a reviewed paid sale to its selected lot, movement and receipt. Current support is one material and one lot per whole sale line. Automatic sale consumption, edited/refunded-order corrections, split lots, multi-material recipes and Google Sheets synchronization remain unfinished. C-Trax retail sales do not automatically enter the Shopify-only material workflow.

Details: [shared-stock comparison](shared-stock-comparison.md), [C-Trax stock and counts](../ctrax.md), [inventory workflows](inventory-workflows.md). Roadmap: F09–F13, F33–F35, F50 and F59. The on-hand worksheet change improves a local audit; it does not authorize source writes or establish physical stock accuracy.

## Payments: next gates before primary checkout

| Next action | Owner | Acceptance evidence |
| --- | --- | --- |
| Confirm Herbal Healers’ actual merchant account, Valmar gateway/backend, approved channels and intended PAX payment application/SDK. | Business owner + provider | Store-specific account and integration confirmation. Historical evidence for another business does not authorize this store. |
| Obtain intended Authorize.net test checkout access or a dedicated NMI sandbox merchant with tokenization, REST and Query permissions. Configure the separate per-store checkout settings. | Business owner + implementer | Correct account/environment and hosted form verified; reporting credentials/checks alone do not prove checkout access. No shared key rotation solely to enable reporting. |
| Run vendor-connected acceptance of the implemented checkout. | Implementer + operator | Approval/decline, fresh tokens, tax/tip repricing, stale customer confirmation, double/concurrent submit, lost response followed by read-only recovery, account isolation and exact receipt totals. Fixture tests are not vendor acceptance. NMI sandbox receipts create no live revenue or stock. |
| Complete the workflows Derrick actually requires. | Implementer + operator | Refunds/voids/tip reversals, discounts, split/gift tenders, variable-price items and cash drops as required. Existing local order refund records do not return money or restock. |
| Implement/verify approved PAX or other card-present terminal integration if required. | Provider + implementer | Intended hardware/payment application passes its own test matrix. Hosted browser card entry is not EMV/contactless terminal execution. |
| Reconcile a trading day and later refund from register through gateway batch, fees/payout and actual bank deposit. | Operator/bookkeeper + implementer | Exact source identities and period/currency/location coverage agree; missing/open/cross-day evidence stays unknown and overlapping reports are never summed. |
| Train, prove fallback, and conduct explicitly approved controlled live acceptance. | Business owner + staff | Written signoff covers checkout, failures, refunds, stock effects and daily close before replacing the existing POS. |

Authorize.net browser capture/recovery is implemented conditionally; it is no longer accurate to describe all Rupert payment work as credential checks only. NMI remains explicitly sandbox-only with production charging blocked. The actual Herbal Healers gateway and a successful Rupert merchant round trip remain unconfirmed here. Historical Next Stage/NMI evidence for Deep Run Hemp does not resolve those gates.

Details: [retail checkout](../ctrax-retail.md), [NMI sandbox safeguards](nmi-sandbox-checkout.md), [provider setup](payment-integrations.md), [POS acceptance](pos-parity.md), [money reconciliation](money-reconciliation.md). Credentials, original reports and merchant/contact evidence belong in encrypted private setup/owner records, never public Git or chat.

## Daily pilot and operations

- Morning: review source-specific successful acquisition and observation times in Credentials & sync, then stock comparison, ambiguous/stale findings, local holds and bulk balances. A configured schedule is not evidence of fresh vendor delivery.
- During the day: continue the accepted checkout path; use Rupert’s reviewed counts, local holds and bulk receipts within their documented limits. Enable no new payment or stock-write setting just to test a screen.
- Close: review native/local register controls, missing evidence and dated follow-ups; independently verify gateway and bank settlement. Keep counts, refunds and material corrections traceable.
- Staff: assign minimum roles, link active workers and name count/time/close reviewers. Commission output remains a preview until basis, refunds, rounding and payout policy are approved.

SQLite/WAL and the existing SER8 Incus deployment remain the production choice. Keep the established worker configuration unless measurements justify a change. October 17’s [migration and recovery checkpoint](combined-release-recovery-2026-10-17.md) includes explicit migration down/up and idempotence checks, saved-key restoration and a decrypted/checksummed off-host copy. Both pre-release and fresh post-release archives were restored and verified off-host; maintain recovery protection as business records change. Google Drive backup and document-retention consent remain separate pending access work; local/off-host checkpoint evidence does not establish a working six-hour cloud schedule. See [Google backup verification](google-backup-verification.md).

For the next change, read `AGENTS.md` and [branching/deployment rules](../BRANCHING.md), inspect current main **and** the live revision, preserve newer concurrent work and take private recovery points. Deployment does not follow automatically from a Git merge. Never restore an old business database over newer transactions or disable host security to force a restart. No source read, sync, messaging job, merchant action or schedule change is authorized merely by opening this plan.

**Next slice after native on-hand worksheets:** prove a representative physical inventory sample and the correct merchant sandbox path in parallel. Follow with the explicitly required correction/refund workflows and operator acceptance; defer alternate POS adapters and broader ERP expansion until these daily-use gates pass. Record each reviewer/date/evidence privately and leave unchecked gates open.
