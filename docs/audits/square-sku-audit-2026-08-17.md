# Audit — Square SKU inventory (live API vs mirror vs Shopify)

Date: 2026-08-17
Scope: deep, read-only audit of SKUs in Square, pulled from the live Square API
(`connect.squareup.com`, 2 active locations: *Herbal Healers LLC*, *Vendor Events*)
and cross-referenced against the local mirror (`SquareVariation` / `SquareItem`),
`SkuLink`, and Shopify variants.

Reusable tooling added:
- `bin/rails ops:audit:square_skus` — prints the full live-vs-mirror-vs-Shopify breakdown.
- `bin/rails ops:audit:prune_stale_mirror` — DB-only cleanup of mirror rows no longer in live API.
- Full per-variation remediation plan: `docs/audits/data/square-sku-plan-2026-08-17.txt`.

---

## Headline numbers

| Metric | Count |
|---|---|
| Live Square variations (API) | 701 |
| — with a SKU | 654 |
| — **without a SKU** | **47** |
| Mirrored in DB (`SquareVariation`) | 701 (after pruning) |
| — live but NOT mirrored (missing) | 0 |
| — stale mirror rows pruned (deleted on Square) | **7** |
| Duplicate SKUs (same SKU, >1 variation) | 1 |
| Unlinked Square variations (no `SkuLink`) | 660 |
| — of which **sellable (qty>0)** | **169** |
| — of which sellable AND no SKU | 6 |
| Shopify variants w/o a matching Square SKU (excl `ROUTEINS`) | 5 |
| Variations with zero/absent inventory | 502 |

---

## Key findings

### 1. The mirror is now clean
All 701 live variations are mirrored; no gaps. 7 stale rows (removed SKUs, e.g.
`749213Z` + its 7g/14g/28g siblings) were pruned along with 14 inventory levels and
11 movements. Re-run `ops:audit:prune_stale_mirror` after each sync to keep it that way.

### 2. The linking gap is structural — not a SKU-typo problem
Only **44 distinct SKUs** exist across the 268 Shopify variants, and **none** of the
169 sellable-but-unlinked Square variations shares a SKU with a Shopify variant.
All 63 existing `SkuLink`s were auto-created by SKU match; the 169 unlinked ones
can't be linked that way.

### 3. Biggest blind spot: sellable stock with no SKU (6 items)
- `3 Count` (qty 92), `10mg THC - Single` (22), `5mg THC - Single` (13),
  `100 Count` (8), `Orange Soda` (2), `Root Beer` (1) — on hand, invisible to
  SKU-based inventory/linking.

### 4. 47 variations have no SKU at all
Mostly the "3.5 Grams" flower re-stocks, THC drink singles, single cans, and the
"Single - Blood Orange" family. These can never auto-link until granted a SKU.

### 5. One duplicate SKU
`388062y` on two variations (`A2UGQPXJ46WTKZ3NOD5G4VZJ`, `JKUELNZVZNJ5ONCI2EJ34FBL`).

### 6. Only 5 real Shopify variants unmatched (excl `ROUTEINS`)
All the same `agzoap5` ("5 Grams" live resin) across 4 resin products, plus
`PETTREAT` (CBD Pet Treats). The other 76 unmatched are `ROUTEINS` shipping-protection
helpers (correctly `tracked=false`, non-sellable).

---

## Recommended next step (blocked by current rules)

The viable fixes for the 169 sellable-unlinked variations are:
1. **Name-based linking** where it's confident (e.g. `6oz Bottle` → Liquid Harmony,
   `10/20 Count` → 10mg THC + CBD Gummy Squares), and
2. **SKU assignment in Square** for the no-SKU AND generic-"Regular" items.

Both touch SKUs / links on Square — currently **blocked** by the "No SKU changes
right now" directive. Re-run `ops:audit:square_skus` after that rule lifts to
action the plan file.

---

## UPDATE 2026-08-18 — remediation applied (rule lifted)

The "No SKU changes" rule was lifted and the plan was executed via the new
`SquareSkuRemediator` service (`ops:remediate:square_skus[apply]`):

| Item | Before | After |
|---|---|---|
| Variations without a SKU | 47 | **0** |
| Duplicate SKUs (shared) | 1 | **0** |
| Sellable AND no SKU | 6 | **0** |
| SkuLinks | 63 | **64** (+1 confident named link) |

- Assigned generated SKUs (lowercase item-variation slugs) to all 47 no-SKU
  Square variations via UpsertCatalogObject (full-replacement, fresh-versioned,
  preserving all fields incl. location overrides).
- Fixed the duplicate `388062y` → `388062y-2` on the second variation.
- Created 1 confident named link (Pineapple Trainwreck → King Cone Pre-Roll).
- Deliberately did **not** auto-link the remaining generic sellable-unlinked
  variations ("3.5/7/14/28 Grams", "Regular") — those need manual strain mapping.
- Re-ran a Square mirror sync; the DB mirror now shows 701 variations, 0 no-SKU.

Remaining known gap: **168 sellable-but-unlinked** variations (mostly generic
flower-size "N Grams" and "Regular" items) still lack a Shopify `SkuLink` because
their Square naming doesn't match Shopify's product structure. These need either
manual mapping or per-item SKU alignment with Shopify's scheme.
