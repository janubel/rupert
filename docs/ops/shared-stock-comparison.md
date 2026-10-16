# Shopify and C-Trax stock comparison

Stock → Stock comparison opens `/stock_comparison`; `/inventory` opens the same view. Inventory read permission is required for HTML and CSV. Page reads never contact providers or change counts, SKUs, mappings or reservations. Square does not participate.

Select one Shopify location and one C-Trax store. A sole stock-bearing Shopify location and sole C-Trax store are selected automatically; multiple eligible locations require a choice. Only current active tracked Shopify variants appear, excluding shipping protection. All records in the selected C-Trax snapshot remain reviewable.

Shopify on-hand, available and committed are separate signed native quantities. Missing stock stays unknown. Source observations are never added together. Unknown, fractional, untracked or over-one-hour-old observations have no numerical difference. A unique native variant identifier takes precedence; otherwise a nonblank trimmed case-insensitive SKU must identify exactly one current record on each source. SKU pairs remain labeled candidates. Conflicting/duplicate identities stay unpaired. Names and prices never silently create mappings. Alternative bulk sizes may draw from the same gram pool; do not sum their sellable quantities.

Search, attention and unmatched filters apply to HTML and CSV. Each HTML page contains up to 50 rows. Counters count comparison rows, not physical units. CSV text is escaped against spreadsheet formulas. No current match does not mean not carried.

## Catalog freshness

All Shopify product statuses and every catalog/variant/location/stock page are read. A complete validated read updates native active/archive/draft statuses and records catalog presence. Missing products/variants remain as history with `catalog_present=false`; quantities, source IDs and sales references are not cleared or deleted. Records without a completed catalog presence observation are excluded from the comparison until a read succeeds.

Signed native stock snapshots and catalog presence publish atomically after validation. Incomplete pages, duplicate identities, missing requested stock states, repeated cursors, cross-workspace IDs or an older concurrent stock read retain the previous publication. A complete empty catalog can mark old records absent without zeroing their stock. Other historical screens retain the old mirrors; this comparison does not infer on-hand stock from a clamped available mirror.

The existing Shopify/C-Trax read schedules supply the observations. Complete a Shopify read after deployment to populate the new snapshots. Read timestamps identify observations, not guaranteed shelf quantities or vendor synchronization. This release adds no inventory writer or equalization job.

## Deployment and recovery

The additive migration adds nullable catalog presence/read-time fields and a separate Shopify stock-snapshot table. Rehearse on a consistent production copy, preserve prior business records/count values and runtime encryption keys, and check both adapters. Promote under `/var/lock/rupert-deploy.lock`, checking the exact prior revision and incorporating newer live changes first. Rebuild assets and restart web/jobs. Verify a complete catalog read, signed stock states, real-data HTML/CSV permissions and backup restoration.

Roll back code without dropping the added fields/table. Never restore an old business database over newer transactions automatically. This rollout does not authorize stock pushes or SKU edits.
