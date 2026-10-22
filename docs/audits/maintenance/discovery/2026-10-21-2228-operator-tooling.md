# Operator-gap tooling discovery — 2026-10-21

Manual maintenance review against `origin/main` at `3fd1d0ad` (the default branch). This report records research and adoption decisions; it does not change Rupert's feature catalog or certify any merchant workflow.

## Baseline and active work

- The requested checkout was `rust-core` at `a5dd29a`, tracking the archived `origin/archive/rust-core`; its upstream tracking ref is gone. GitHub identifies `main` as the default. `origin/main` contains the current Rails modular monolith and later inventory, C-Trax and checkout work. Do not merge the Rust branch into production wholesale.
- The current mainline operating model is C-Trax as the retail stock reference, Shopify as a mostly shared-stock observation, and Square disabled. Shopify and C-Trax are different observations of overlapping stock, not additive pools. The C-Trax variant/store identity remains distinct; count differences alone do not authorize equalization or writes.
- Rails is the built and deployed application path in current operator documentation. The October 17 readiness and release records report production `b5e2a40` for the timesheet workspace and `96da470` for the combined release. Those records establish deployed source checkpoints, not physical-count, merchant account, processor, terminal, or operator acceptance. The local default branch has moved beyond those checkpoints; GitHub push/merge is not deployment.
- Inventory count comparison, C-Trax stock snapshots, native Shopify on-hand worksheet snapshots, barcode-entry scan receipts, and server-side source/location checks are implemented in Rails. Camera scanning and offline queueing are still roadmap items. The available scanner screen uses an exact code field compatible with a keyboard-wedge scanner; a camera library alone would not solve source identity, count basis, retries, or approval.
- The mobile package is the employee timesheet client. It does not currently include `expo-camera` or an inventory workflow. Open PR #300 targets `main` and restores the SDK 58 compatibility set. Do not add inventory camera permission to that app without an accepted mobile inventory scope.
- Open PRs reviewed: #301 local-model exploration, #300 Expo SDK compatibility, #299 serialized upload quota, #295 production logging, #283 ledger posting, #269 Zelle reporting, #243 Pagy, #238 React, and #228 bookkeeping navigation. None is an inventory-camera implementation. PR #269 adds separate bank-file evidence, not verified settlement completeness. No direct duplicate was found for this discovery note.

The baseline comes from [day-to-day readiness](../../../ops/day-to-day-readiness.md), [C-Trax stock setup and identity contract](../../../ctrax.md), [POS parity](../../../ops/pos-parity.md), [`product_roadmap.json`](../../../../web/config/product_roadmap.json), the Rails count services, `mobile/package.json`, and the open PR list as inspected on the review date. Private owner checklists and business records were not read or copied.

## Ranked candidates

Rank reflects the documented Rupert operator gaps and useful workflow leverage, not popularity. “Fit” assesses use as a reference or candidate, not acceptance for production.

| Rank | Candidate and useful idea | Maintenance / license / security | Rupert fit, cost and decision |
| --- | --- | --- | --- |
| 1 | [ERPNext Stock Reconciliation](https://docs.frappe.io/erpnext/stock-reconciliation): assigned counts, warehouse context, barcode scan mode and an explicit reviewed submission step are a useful physical-count workflow reference. Its barcode workflow distinguishes scan-to-add from importing book quantity. | Active upstream code; package metadata declares GPL-3.0. A deployed ERPNext instance would add another large Python/Frappe system, storage and security patch stream. | High workflow value for count setup and staff handoff; poor code reuse with Rails and Rupert’s source-specific comparison snapshots. Study interaction patterns only. Do not import its stock ledger or add the dependency. An adoption gate is a reviewed sample proving C-Trax store/variant and Shopify location/variant identity, correct on-hand basis, no cross-source summation, and no stock write on approval. |
| 2 | [Odoo Barcode inventory adjustments](https://www.odoo.com/documentation/master/applications/inventory_and_mrp/barcode/operations/adjustments.html): assigned location/product count tasks and location-first scanning suggest a good operator sequence for future camera or receiving work. | Odoo Community source is LGPL-3; Enterprise modules and hosted functionality have separate licensing/availability. Product documentation can describe capabilities not available in every deployment/edition. A full Odoo integration adds an independent ERP and another access-control surface. | Strong interaction reference, weaker architecture fit: Rupert already has Rails count worksheets and a separate source identity contract. Avoid replacing them or assuming Odoo's stock locations map to Rupert's source locations. Reconsider only if a concrete workflow gap survives a staff pilot and required Community/Enterprise boundaries are verified. |
| 3 | [Expo Camera for SDK 58](https://docs.expo.dev/versions/v58.0.0/sdk/camera/): barcode callbacks support common linear and 2D types on Android/iOS/Web and can pass scanned text to an exact-code resolver. | First-party Expo module with SDK-matched versioning; its plugin requests camera permission (and has separate microphone configuration). Runtime uses device/platform scanning implementations. No captured image is necessary for a scan flow. | Lowest implementation cost for a future native inventory client, but not for the current employee-only app. It would require an inventory client/API contract, explicit camera permission rationale, deduplication/debounce, code allowlist, scanner fallback, connectivity/retry handling, and device testing. Keep the current keyboard-wedge path. Re-evaluate after the mobile inventory scope and source/location API are accepted. |

### Deep assessment: ERPNext count workflow

ERPNext is the most useful workflow reference because the central Rupert gap is count confidence, not another broad ERP subsystem. Its official guide describes setting a default warehouse, enabling scan mode, and incrementally adding scanned quantities; its general stock-reconciliation flow also distinguishes entering a physical balance and submitting a reconciliation. Those interaction choices can inform a Rupert worksheet without adopting ERPNext's data model.

The critical mismatch is that ERPNext reconciles a warehouse's book stock as part of its own stock ledger. Rupert must preserve independently observed C-Trax and Shopify quantities and use exact native source/location identities. Copying ERPNext's “reconcile” semantics could wrongly imply equalization, or turn an audit approval into a platform write. Rupert's current server keeps approval separate from source mutation, snapshots source identity and quantity, and represents missing/ambiguous values as unavailable. Preserve those safeguards.

No source/fixture prototype was justified in this run. The existing Rails count workflow already covers scan receipt idempotency, selected source/location and review. A separate ERPNext-based model or SDK sample would test a second system rather than the unresolved operator questions. The next valuable evidence is a private, operator-reviewed physical sample against native C-Trax store/variant and Shopify location/variant records, followed by an explicit count correction policy. This run neither accessed those accounts nor performed a physical count.

### Deliberately not shortlisted

- `html5-qrcode` has an upstream maintenance-mode notice; it is not a good new dependency for a reliability-sensitive count workflow.
- A QuickBooks/Xero adapter cannot be responsibly selected from open-source popularity: Rupert's roadmap requires statement matching and reconciled exports, and the live account, supported connection path, and transaction mapping are not established by this repository review. Existing ledger/bank evidence work remains active. Revisit after operator-selected accounting target and acceptance examples exist.
- No alternate POS or ERP provider should be added before the existing C-Trax/Shopify stock and payment acceptance gates pass.

## Decisions and gates

1. Keep inventory source observations, store/location IDs, count basis and unavailable states in the Rails domain layer. Do not sum C-Trax and Shopify or normalize their quantities to match.
2. Keep keyboard-wedge scanning as the supported path. Gate camera scanning on an accepted mobile inventory client scope, an authenticated exact-source/location API, device permission review and physical-device tests. Prefer the SDK-compatible Expo module over a standalone browser scanner only if that gate passes.
3. Use ERPNext/Odoo solely as workflow references. Their stock-ledger behavior is not a substitute for Rupert's audit-only worksheet or owner-approved source-write boundary.
4. Avoid new dependencies, provider accounts, merchant data collection, catalog claims, and catalog/roadmap edits in this discovery run. No new factual Rupert feature claim was established.

## Checks and evidence limits

- Inspected the repository instructions and current mainline docs/code; fetched `origin/main`, verified remote default branch, reviewed open PRs, and started an isolated branch from `origin/main`.
- Reviewed primary sources: ERPNext stock reconciliation and barcode documentation, ERPNext repository package/license metadata, Odoo barcode adjustment documentation and source license, versioned Expo SDK 58 camera documentation, and the project's readiness/roadmap/architecture documentation.
- No application tests, provider calls, production access, deployment, account changes, source-data reads, inventory writes, payment/refund/terminal operations, or mobile release actions were performed. Source documentation and code do not establish real platform or operator acceptance.

## Next iteration

After an owner-authorized inventory operator completes a small private physical sample, review the discrepancies and decide whether Rupert needs a count correction workflow before building camera scanning. Keep the evidence in the private owner checklist; do not publish merchant rows or account details.
