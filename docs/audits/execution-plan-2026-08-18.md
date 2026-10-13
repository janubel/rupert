# Execution plan — resolve Square ↔ Shopify SKU divergence + gaps

Date: 2026-08-18
Owner directive: **everything in Square must exist in Shopify**; the
**no-SKU-changes rule is overridden** to resolve this. Square stays the
**source of truth** for SKUs; Shopify inherits them. Plan-only — **nothing
written yet.** Execution is gated by the push-guard (both platforms currently
LOCKED; needs an approved push window to write).

Derived read-only from the live Square + Shopify APIs (see
`square-shopify-inventory-audit-2026-08-18.md`).

---

## The three-part plan

### Part 1 — Automatic Shopify SKU rewrites (13, high-confidence)
`data/execution_plan_shopify_sku_rewrites.csv`

Unambiguous 1:1 variation matches — set the Shopify variant's SKU to Square's
so `SkuLink` auto-links. Examples:
- `Gata 25mg THC Drinks` flavors → `gata-juice-25mg-thc-drinks-*`
- `Liquid Serenity 6oz Bottle` → `R751387`
- The 5 `Tier 2 Rosin` 1-Gram variants (currently sharing `DSLR1`) → their own
  distinct Square SKUs (this also fixes the shared-SKU issue).

### Part 2 — Products to create on Shopify (126 items / 344 variations)
`data/execution_plan_create_products.csv`

Every Square item with no Shopify counterpart — create on Shopify carrying its
Square SKUs + current Square quantities. 54 are sellable (~741 units); the rest
are zero-qty (still created so the catalog matches, per the directive).

### Part 3 — Needs manual confirmation (118) — DO NOT auto-apply
`data/execution_plan_confirm.csv`

Two kinds:
- **62 weak-item matches** — Square items that fuzzy-matched a Shopify product
  at 0.25–0.45. Many are *false* matches (different strains sharing words like
  "hybrid"/percentage), so these are more likely **Part-2 creates**, not aligns.
  Example false matches: `Papaya` → `Blockberry`, `Red Thai` → `Orange Crush`.
- **56 multi-variant matches** — Square item matched a Shopify product but the
  variation→variant mapping is ambiguous (e.g. `Greasy Runtz` → `Dragon` sizes,
  `Papaya Punch Live Resin` → `agzoap*`). Need a per-item decision.

These must be reviewed by eye before anything is applied.

---

## Execution order (once a push window opens)

1. **Confirm the 118 ambiguous items** (Part 3) — split into "align" vs "create".
   This is the only manual work; the 13 + 126 are deterministic.
2. **Apply Part 1** — Shopify SKU rewrites (small, lowest risk, unblocks links).
3. **Apply Part 2** — create the confirmed set of products on Shopify.
4. **Add `SkuLink`s** for everything now sharing a SKU (engine will do this on
   next sync).
5. **Re-run the audit** to confirm Square↔Shopify drift → 0.

---

## To unlock execution (owner action required)

Both platforms are **LOCKED** (push-guard, 0/2 approvals, no window). To write:
- Shopify: `bin/rails ops:push_guard:approve[shopify,<email1>]` then
  `...<email2>` (2 distinct approvers) → opens a 60-min window.
- Square: `bin/rails ops:push_guard:approve[square,<email1>]` then
  `...<email2>` if any Square writes are needed (currently planned: none — the
  plan only rewrites Shopify SKUs and creates Shopify products).

The plan is staged so the safe parts (Part 1 + Part 2) can proceed as soon as
Shopify's window opens, while Part 3 is reviewed in parallel.