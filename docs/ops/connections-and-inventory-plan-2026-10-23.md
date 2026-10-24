# Connections audit and inventory plan (2026-10-23)

A read-only audit of every connection on production (Herbal Healers, checked 18:39 ET) and the code that reads
it, followed by a plan for inventory. Nothing was changed on production by the audit.

## 1. Connections: where we stand

| Source | Verdict | What matters |
| --- | --- | --- |
| **SwipeSimple** (main store register since Oct 2026) | **Failing since 10-21 11:01** | A second merchant account (the PAX A920 terminal) broke the one-account check: 109 failed pulls, no transactions, invoices, reports or items for 2+ days. Fixed in PR #447 (not deployed). Tax/sales report history only Sep–Oct 2026; transactions reach back to Feb 2025. |
| Google Drive backup | **Not configured: no off-site backup exists** | No refresh token, 31 skipped runs, zero backups. When connected it keeps only 7 copies (~42 h). |
| Shopify catalog, stock, orders, customers | Healthy | Orders only from 2026-06-23 (check the app has `read_all_orders`); every order is labelled `online` with no location. Staff directory has failed every run since 10-16 (likely missing `read_users`). |
| Square catalog, stock, orders, timecards, customers | Healthy | No Square sales since 2026-09-28. Reads stop silently at the first 10 locations and at 100k orders while the watermark advances. A missing count is stored as 0. The `square_integration_paused` setting is not read by any code. |
| C-Trax stock | Healthy feed, poor data | One snapshot kept (no history); cost dropped; 127 negative and 116 missing quantities (see §2). |
| C-Trax daily sales | Healthy feed, check data | 370 days stored but **none from Oct 2025 to Aug 2026**; 0 orders on 10-22 and 10-23 (is the C-Trax register retired now that SwipeSimple is the register?). Each run re-reads only today and yesterday. |
| C-Trax labor, customers, employees | Healthy | Labor re-reads full history every run and fails past 10,000 shifts. |
| NAB/IRIS daily deposits | Healthy | Website pull of deposits only, previous and current month. Batches, chargebacks and statements are not pulled. |
| Authorize.net | Not configured (API); portal CSV stale since 10-15 | |
| Document retention to Drive | Not configured | |
| Bank statements, QuickBooks, Zelle, uploads | Manual | Bank lines through 10-22; QuickBooks has the chart of accounts only. |

Jobs: workers and scheduler are alive and every source task runs. Two housekeeping faults: 25 hourly jobs wait on
the `solid_queue_recurring` queue, which no worker serves (`config/queue.yml` lists only `default` and `chat`), so
finished jobs are never cleared; and 5 sync attempts from Oct 16–22 are stuck at "running". The 10-20 failures were
one network outage (01:00–11:00 ET) across all sources.

### Connection fixes, in order

1. **Deploy PR #447** (SwipeSimple multi-account), then run `swipesimple:backfill_reports` for Feb 2025 onward.
2. **Connect the Google Drive backup** (owner: complete the consent flow) and raise retention beyond 42 hours.
3. **Queue housekeeping**: add `solid_queue_recurring` to the default worker; close the stuck attempts.
4. **Square silent truncation**: page through all locations and stop the watermark when the 100k cap is hit;
   store a missing count as unknown; make `square_integration_paused` do what it says or remove it.
5. **C-Trax sales**: backfill the Oct 2025–Aug 2026 gap; re-read the last 7 days each run so edits are seen.
6. **Shopify**: confirm `read_all_orders` and `read_users`; record the POS location and channel on orders.
7. **Scale limits**: split the SwipeSimple export before 10,000 rows; incremental C-Trax labor and Square timecards.
8. Later: IRIS batches/chargebacks, Authorize.net API (owner deferred key work), QuickBooks transactions.

## 2. Inventory: the problem in one paragraph

C-Trax was chosen on 10-15 as the retail physical-count reference, but it cannot play that role yet: 95% of its
419 variants have no SKU, only 37 of 513 C-Trax/Shopify rows pair up, 127 quantities are negative and 116 are
missing, cost is dropped and there is no history. Meanwhile the signals people see are misleading: 503 of the 627
open low-stock alerts are for products no longer active (they can never close), alerts look only at Shopify, the
negative-stock check misses 50 oversold Shopify rows, stock sits on the non-primary Shopify location while size
family writes target the primary, and the reorder helper (`RestockAdvisor`) counts only Shopify and Square sales,
so the store's main register sales never count toward a reorder. Inventory counts and scan receipts have never
been used (0 records); reconciliation runs have been stuck since 2026-08-19. Pairing suggestions exist
(`StockIdentityMatcher`) but are never saved, so the same 476 unpaired rows come back every time.

## 3. Inventory plan

Principles: C-Trax stays the count reference; nothing is written to Shopify, Square or C-Trax without the owner's
sign-off (AGENTS.md); unknown is never zero; every recommendation shows why.

### Phase 0: stop the misleading signals (days)

- Close or hide alerts for products that are inactive or gone; show alert age.
- Negative stock from the raw source quantity (`sourceQuantity`), across Shopify, Square and C-Trax.
- Alerts and negatives for C-Trax and Square, not only Shopify, each labelled with its platform and location.
- Size-family writes go to the Shopify location that actually holds the stock (owner sign-off before any write).
- **Owner decision**: the C-Trax stock write on POS checkout is armed (`PosSetting.stock_writes_enabled` on, 0
  checkouts so far). Confirm or switch off.

### Phase 1: pairing (one product, every platform)

- Save pairs: a confirmed link between a C-Trax variant, Shopify variant, Square variation and SwipeSimple item,
  owner- or staff-confirmed, stored in Rupert only (no platform writes).
- A pairing workbench: every unpaired item with the matcher's suggestions ranked by confidence and **the evidence
  shown** (same SKU, same barcode, same name and size, same price, sold on the same days), with Accept / Reject /
  Not sold elsewhere. Rejected suggestions are remembered.
- Coverage as a number on Inventory: "C-Trax items paired: 37 of 419 (9%)", by category, with the goal of 90%.
- Missing SKUs: propose a SKU per paired product (from Shopify or Square where one exists). Writing SKUs to any
  platform needs explicit owner sign-off; the proposal list can be exported for C-Trax entry.

### Phase 2: quantities you can trust

- Keep a daily C-Trax stock snapshot (history for drift and sales-vs-stock checks) and keep cost.
- Store Shopify on-hand and committed, not only available; Square all states; missing counts as unknown.
- One stock view per paired product: each platform and location side by side, the reference (C-Trax) first,
  drift marked when platforms disagree.

### Phase 3: counts and reconciliation

- Cycle counts on the existing `InventoryCount` flow, scheduled by category, starting with negative and drifting
  items; scan receipts for deliveries.
- A drift queue: paired items where platforms disagree with the C-Trax count, oldest and largest first, each with
  the count history and recent sales.
- Restart reconciliation runs (stuck since August) only for paired items, as proposals for owner approval.

### Phase 4: recommendations with context

- Reorder from **all** sales: the SwipeSimple and C-Trax registers plus online and Square, per paired product
  (register lines need item detail: SwipeSimple items, C-Trax order lines with quantity and SKU, which are dropped
  today).
- Each recommendation says why: sold per channel in the last 14 and 30 days, on hand per location, days of cover,
  last count, and how sure it is (paired or not, counted recently or not). No pairing means "can't recommend yet".
- Also: dead stock (on hand, no sales in 60 days), items selling in-store but missing online, negative stock that
  needs a count.
- In chat: an `inventory_advice` tool with the same rows and reasons, so @rupert can answer "what should I
  reorder?" (today it cannot).

### Phase 5: pushing stock (later, owner sign-off)

Only after pairing coverage passes 90% and the drift queue is under control: owner-approved pushes from the C-Trax
count to Shopify and Square, per product, with a preview and an audit trail.

## 4. Decisions for the owner

1. Deploy the open PRs (#447 first) so SwipeSimple syncs again.
2. Connect the Google Drive backup.
3. C-Trax stock write on POS checkout: keep or switch off?
4. Is the C-Trax register retired now that SwipeSimple is the store register? (It shows 0 orders since 10-21.)
5. Shopify app permissions: `read_all_orders`, `read_users`.
6. Who confirms pairs: owner only, or bookkeepers and managers too?
