# Audit — Square ↔ Shopify inventory (items missing from where)

Date: 2026-08-18
Method: **read-only** pull of the live Square API (`connect.squareup.com`,
2 active locations: *Herbal Healers LLC*, *Vendor Events*) and the live Shopify
Admin API (shop *Herbal Healers*, `m11u0i-sb.myshopify.com`). No writes to
either platform or the database. Matching is by SKU (the engine's link key)
*cross-referenced by item name* so we can separate genuine gaps from the known
SKU-scheme divergence.

Reusable artifacts (committed in this folder):
- `data/square_missing_from_shopify.csv` — Square items with no Shopify counterpart.
- `data/shopify_missing_from_square.csv` — Shopify variants with no Square counterpart (excl. wholesale + ROUTEINS).

---

## Headline

| Source | Items | Variations / Variants | SKUs |
|---|---|---|---|
| Square (live) | 233 items | 697 variations | 697 (all have a SKU) |
| Shopify (live, active) | 57 products | 246 variants | 170 have a SKU |

> Note: the earlier Square audit (2026-08-17) saw 701 variations; live is now
> **697** (4 fewer), all SKU-bearing.

---

## The root cause first: the two platforms run different SKU schemes

A SKU-only comparison is misleading because Square and Shopify use **entirely
different SKU identifiers for the same physical product**:

- Square flower strain: `K239116`, `782244Q`, `GUM-100-BLUELEM` → no, Square
  uses e.g. `K239116` / numeric codes / lowercase slugs.
- Shopify equivalents: `KUNDALINISHERBET-3.5`, `GIRAFFEPUSSY-7`, `HELIUM-14`,
  `agzoap5`, `GUM-100-BLUELEM`.

Only **62 of 246 Shopify variants (25%)** share a SKU with a Square variation,
and only **16 Square items** SKU-match a Shopify variant. So the current
`SkuLink` (SKU-match based) structurally cannot link ~75% of the catalog. A
naive "missing by SKU" audit therefore over-reports massively in *both*
directions. The numbers below are **name-cross-referenced** to correct for this.

---

## Direction A — Square items not carried on Shopify

Per the stated expectation ("all Square items should be on Shopify"), these are
the gap. Square carries far more than the online store.

| Bucket | Items | Sellable (qty>0) | Units |
|---|---|---|---|
| **Not on Shopify (confident)** | **126** | 54 | 741 |
| Likely-shared but name mismatch (review) | 62 | 20 | 757 |

### Top sellable Square-only items (qty > 0, top 25)
`Can Topper` (146) · `Smoking Dog` (75) · `100MG Nerdz Clusterz` (66) ·
`Wyld CBD Sparkling Water` (52) · `Brez Lemon ElderFlower Social Tonic` (35) ·
papers/lighters/glass (`Single wide classic paper` 31, `King size paper (black)` 26,
`King size paper` 25, `Tips` 23, `clipper lighter` 18, `Glass Bowl` 9) ·
`Diamond Distillate 1G Vape THC Free` (25) · `Rise Sample 2ct` (17) ·
`Rest Sample 2ct` (14) · `Motor Breath` flower (14) · `SwitchBlade` (11) …
(full list incl. all zero-qty items in the CSV)

These break down into:
1. **Retail/vape-shop supplies** — papers, lighters, glassware, grinders,
   butane, Puffco accessories. Likely *intentionally* Square-only (storefront
   impulse items not sold online).
2. **Square-only flower strains / concentrates** — `Motor Breath`, `Ghost OG`,
   `Jack Herer`, `Blue Dream`, `GMO`, `Grape Bubblegum Live Rosin`, `Moon Rocks`,
   etc. Present on the POS, not listed online.
3. **Square-only brands** — `Smoking Dog`, `Wyld CBD`, `Brez`, `Can Topper`,
   `THC Knockout Krispy`, `Kenetik`, etc.

> 62 more Square items match Shopify only *weakly* by name (`sq_review`) — most
> are probably the same product under a differently-worded title/percentage
> (e.g. `Astronaut` vs `Mcflurry`, `Upgrade` vs `Mac 1`) and need a manual
> eyeball before treating them as missing.

---

## Direction B — Shopify items not carried on Square

Excludes the **wholesale-tagged** product (expected Shopify-only) and the
**ROUTEINS** shipping-protection helpers (non-sellable).

| Bucket | Variants | Units |
|---|---|---|
| **Not on Square (confident)** | **25** (all tracked) | 517 |
| Likely-shared but name/SKU mismatch (review) | 39 | — |

### The confident gaps group into two patterns
1. **The CBDA live-resin line (20 variants, ~455 units)** — Shopify-only:
   `Apricot Live Resin`, `Super Suver`, `Sour Warheads`, `Purple Gas`,
   `Mango Fire`, `Chem Berry` (CBDA-derived live resins in 2.5/5/10/25g).
   Square does not appear to carry this CBD line.
2. **A few gummy/edible flavor variants (5 variants, ~62 units)** —
   `100mg THC Gummies` (`Blueberry Lemonade`, `Pink Lemonade`) and
   `50mg THC Gummies (Singles)` (`Blackberry`, `Lemon`, `Blueberry Pomegranate`).
   These flavors may exist on Square under different names (e.g. the
   `Smoking Dog`/`Wyld` flavored items) — see review bucket.

### Review bucket (39 variants, almost certainly shared)
These name-match a Square item at 0.25–0.45 but differ by SKU and/or wording:
flower strains (`Giraffe Pussy`, `Alien Hallucination`, `Astronaut`,
`Candy Zativa`, `Upgrade`, `Dragon`), the `Tier 2 Rosin` line (present on
Square as `Live Rosin`), `King Cone Pre-Roll - THCA`, `Citrus Burst Live Resin`,
`Deep Sleep Microgels`, `CBD Pet Treats`. All of these are **present on both
platforms** — just not SKU-linked.

---

## Expected exclusions (verified correct)

| Category | Why it's not a gap | Count |
|---|---|---|
| **Wholesale-only** (`Afghan Black Hash — Wholesale`, wholesale tag) | Shopify-only, never carried on Square | 8 variants |
| **ROUTEINS** (`Shipping Protection by Route`) | non-sellable shipping helpers, `tracked=false` | 76 variants |

The wholesale tag is being honored by the engine (`square_syncer` skips
`wholesale`-tagged products), so these are *not* counted as missing.

---

## Bottom line

- **Genuinely missing from Shopify (Square-only):** ~126 Square items
  (54 sellable, ~741 units), dominated by retail supplies, Square-only strains,
  and Square-only brands — plus ~62 borderline that need a manual look.
- **Genuinely missing from Square (Shopify-only):** ~25 variants (~517 units),
  dominated by the **CBDA live-resin line** and a few gummy flavors, plus ~39
  borderline that are almost certainly already shared.
- **The bigger, structural issue is not "missing items" but SKU divergence:**
  ~75% of the shared catalog can't be auto-linked because Square and Shopify use
  different SKUs for the same product. That is what makes the platform
  comparison — and the current `SkuLink`/reconcile logic — look so broken.

Recommended next step (no writes made): reconcile the **review** buckets by eye
and align the shared-catalog SKUs so the engine can link them; decide whether
the Square-only retail supplies/strains are intentional and, if so, tag them so
they stop surfacing as "missing."