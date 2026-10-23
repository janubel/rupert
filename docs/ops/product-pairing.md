# Product pairing (Inventory → Stock comparison)

Phase 1 of `connections-and-inventory-plan-2026-10-23.md`. C-Trax is the retail count reference, but on
2026-10-23 only 37 of 513 C-Trax/Shopify rows paired up and the matcher's suggestions were never saved, so the
same unpaired rows came back every time.

- **Coverage** at the top of Stock comparison: "C-Trax items paired: X of Y (Z%)", counting pairs a person
  confirmed and exact matches on the native ID, SKU or barcode. Name-only candidates do not count. Goal: 90%.
- **Review suggested pairs** (filter "To pair") lists suggested but unconfirmed pairs with the matching evidence
  open: same SKU or barcode, same normalized name and package, price and package differences.
- **Confirm pair** saves the decision; **Not the same** stops that suggestion from coming back; **Undo** (on the
  row or in "Pairing decisions") removes it. People with inventory write permission decide.
- Decisions are `ProductPair` rows (per C-Trax store), stored in Rupert only: nothing is written to Shopify or
  C-Trax. Each keeps a fingerprint of both items, so a later change (renamed, new SKU, new size) shows "Changed
  since it was confirmed; check the pair again".
- A confirmed pair is the strongest evidence in `StockIdentityMatcher`, so Stock comparison, SwipeSimple item
  matching and C-Trax daily items all use it. One Shopify item pairs with one C-Trax item per store.
- Changes are in the activity log (`product_pair_decided`, `product_pair_undone`).
