# Inventory Drift Migration Plan (review before running)

**Status: DRAFT — NOT executed.** Created for review before any live write to
Shopify or Square. Applying requires explicit per-strain counts + confirmation.

## Root cause

Four live-resin strains (`agzoap2.5/10/25`) and two gummy flavors
(`689745640858`) share a single Square catalog variation each. Because one SKU
maps to multiple Shopify variants, reconciliation is correctly blocked (shared
pool). The strain/flavor distinctions exist on Shopify but **not on Square**.

Additionally, the `689745640797` cream has stock split across the primary
`Herbal Healers LLC` (PHYSICAL) and the stale `Vendor Events` (MOBILE) location.
Events are discontinued ("we are not at an event anymore"), so the MOBILE stock
should fold back to the primary.

## Live locations (determined)

| Location | externalId | kind | primary |
|---|---|---|---|
| Herbal Healers LLC | `LQ0X40MM4FYAZ` | PHYSICAL | **yes** |
| Vendor Events | `L9RQ7FA9YBFWN` | MOBILE | no (discontinued) |

## Shared pools (Square, home location)

| SKU | squareVariationId | Home qty | Shopify variants |
|---|---|---|---|
| `agzoap2.5` | `GQL2WZ7QAODPRYHIAG4SIAW4` | 180 | Papaya Punch 1, Trop Z 3, Citrus Burst 19, Orange Cheese 17 |
| `agzoap10` | `J7BUE2O7PSQGZAPTVXY3J5ZE` | 45 | 0, 0, 6, 8 |
| `agzoap25` | `EG7YWXKABLHR5PGQXOVQTV37` | 18 | 0, 0, 3, 2 |
| `689745640858` | `M57BLO4XSUGZMPF4BADVNRKR` | 56 | Blood Orange 57, Blue Raspberry 57 |

## Proposed new Square items (per strain/flavor)

Each current shared variation is split into N distinct catalog variations, one
per strain/flavor, with a finalized per-strain physical count (below). Proposed
SKU suffixes match the existing [`SkuRemediationPlanner`](../app/services/sku_remediation_planner.rb).

| Shared SKU | Strain/Flavor | New SKU |
|---|---|---|
| `agzoap2.5` | Papaya Punch | `agzoap2.5-PP` |
| `agzoap2.5` | Trop Z | `agzoap2.5-TZ` |
| `agzoap2.5` | Citrus Burst | `agzoap2.5-CB` |
| `agzoap2.5` | Orange Cheesecake | `agzoap2.5-OC` |
| `agzoap10` | (4 strains) | `agzoap10-PP/-TZ/-CB/-OC` |
| `agzoap25` | (4 strains) | `agzoap25-PP/-TZ/-CB/-OC` |
| `689745640858` | Blood Orange / Blue Raspberry | `689745640858` / `689745640858-TBR` |

## ⚠️ REQUIRED INPUT (blocker)

Per-strain **physical counts** to allocate each shared pool. The table below
lists what needs confirming. Without real counts I will not assign stock, as an
invented split can oversell/understock your store.

```
agzoap2.5 (pool 180):  Papaya=__  Trop=__  Citrus=__  Orange=__
agzoap10  (pool  45):  Papaya=__  Trop=__  Citrus=__  Orange=__
agzoap25  (pool  18):  Papaya=__  Trop=__  Citrus=__  Orange=__
689745640858 (56):     Blood Orange=__  Blue Raspberry=__
```

## Migration steps (once counts confirmed + approved)

1. **Event consolidation (cream `689745640797`)** — move the 10 units at
   `Vendor Events` into `Herbal Healers LLC` (MOBILE cleared). Single-location
   thereafter; unblocks the multiloc guard.
2. **Create per-strain Square variations** under the existing item (or new
   items) with the confirmed counts, using `UpsertCatalogObject` with a fresh
   version read.
3. **Rename the Shopify variant SKUs** to the new unique SKUs.
4. **Re-link** `SkuLink` rows: remove the shared-SKU links, create one link per
   (variant → its new per-strain squareVariationId).
5. **Reconcile** with `ops:reconcile` → expect shared-SKU drift to clear; apply
   with `ops:apply` to bring quantities in line.

## Rollback / risk notes

- Square `UpsertCatalogObject` is full-replacement and irreversible on live
  data; a fresh `RetrieveCatalogObject` is read immediately before each write
  for optimistic concurrency.
- Shopify variant SKU renames are reversible in the Shopify admin.
- Order of operations (Square first, then link, then reconcile) avoids a window
  where the two platforms disagree on linking.
