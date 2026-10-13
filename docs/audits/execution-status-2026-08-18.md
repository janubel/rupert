# Square → Shopify Inventory Parity — Execution Status (final)

Date: 2026-08-18
Owner directive: **everything in Square must exist in Shopify.** Push guard removed; all writes done with explicit owner sign-off and verified live.

## ✅ Part 1 — Shopify SKU rewrites (DONE, verified)
13 Shopify variants updated to their **Square SKU** via REST (with drift-guard + post-write verify). **13/13 aligned.** *(data/part1_result.json)*

## ✅ Part 2 — Create missing Square products (DONE, verified)
126 Square-only products created **Active** via REST (variants with Square SKU + price), each re-fetched by ID:
**126 products / 344 variants · 0 missing · 0 SKU mismatches.** *(data/part2_result.json)*

## ✅ Part 3 — In-stock deferred items (DONE, verified)
The 20 **sellable** (qty > 0) items previously in REVIEW were created as standalone products via the same REST flow:
**20 products created · verified matched=20 · 0 missing · 0 SKU mismatches.** *(data/part3_result.json)*

## 📊 Final live reconciliation (Square → Shopify)
- **ALIGN: 193**  ·  **REVIEW: 39**  ·  **ADD: 1**
- **Every in-stock (qty > 0) Square item exists on Shopify: TRUE** ✅
- Remaining 40 gaps are **all zero-stock** (out of stock in Square) — intentionally deferred:
  - 39 REVIEW (weak fuzzy matches, distinct strains/concentrates with no inventory)
  - 1 ADD — `Northspore Functional 5 Mushroom Blend 70% Dark Chocolate Bar` (SKU `6239796`, qty 0), a genuine zero-stock gap exposed by scoring re-run.
- Shopify → Square (informational, not required): ALIGN 508 / REVIEW 38 / ADD 25 (Shopify-only items like the CBDA line).

## ⏳ Deferred — 40 zero-stock Square items
Listed in `docs/audits/data/square_missing_from_shopify.csv`. All currently carry no sellable stock in Square. Can be created later for full parity, or handled when restocked.

## Method notes
- This Shopify API version's variant inputs have **no `sku` field** — products are created via REST `POST /products.json` (title + options + variants with `option1`/`price`/`sku`), which handles option mapping in one call. SKUs land at creation.
- Inventory auto-flows afterward via the sync loop (SKU-linking + `InventoryMaintainer`).
- Fuzzy name-matching is unstable at the edges (a few items re-classify between runs as the product pool grows), which is why the remaining gaps are all cross-checked by SKU/qty rather than relied on by name.

## Files
- `data/part1_result.json`, `data/part2_result.json`, `data/part3_result.json` — per-part verification
- `data/reconciliation_square_to_shopify.csv` / `data/reconciliation_shopify_to_square.csv` — current reconciliation
- `data/square_missing_from_shopify.csv` — the 40 zero-stock deferred gaps