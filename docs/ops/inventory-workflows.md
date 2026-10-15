# Inventory workflow operations

Reviewed 2026-10-15. These workflows record local work in Rupert. Shopify and Square remain independent inventory pools. They do not push platform stock, edit SKUs, collect payments or guarantee availability in another channel. Inventory read permission is required to view them; inventory write permission is required to change local records.

## Inventory exception review

Open **Stock → Inventory review** to inspect stored negative/unknown/stale stock, broken source/location/item identities, excessive or unverifiable local holds, duplicate SKUs/barcodes, unresolved/shared catalog links, incomplete Shopify source orders, pending counts and depleted bulk lots.

Choose a platform, stock location, work type and stale threshold of 1–168 hours. Stock and holds use exact source/item/location pools. Catalog identity checks are source-wide; bulk lots have no platform/location assignment. Order-location filtering maps the stock location to its Shopify external ID and excludes unassigned orders. Coverage notes explain each filter.

Each check returns at most 50 matching records/groups in the operator UI. Duplicate members are sampled, with at most five IDs displayed per group. Pagination covers these bounded results. A pool can produce multiple issue rows; totals are neither unique-product counts nor a complete audit. Review links do not repair mirrors, apply counts or change reservations.

## Catalog identity decisions

Use an item's inventory detail page to choose an exact Square variation or explicitly unlink it. Source syncs preserve manual/audit choices and explicit unlinks. An explicit unlink remains in place until an operator chooses another link.

Automatic matching requires a nonblank normalized SKU to identify exactly one Shopify variant and one Square variation in this store. Duplicate candidates or conflicting source IDs remain unresolved. Manual linking takes precedence over competing automatic claims; other deliberate shared mappings remain visible for review. Local mapping decisions serialize per tenant. A link identifies a sellable item; it does not merge the two channels' stock or change a source SKU.

## Scanner counts

Open **Stock → Counts**, create or open a draft worksheet, and choose **Scan items**. A keyboard-wedge scanner enters a SKU or barcode already stored in Rupert. Unknown or ambiguous codes require review. The catalog importer currently imports SKUs but does not populate the Shopify barcode field, so SKU scanning is the immediately supported workflow.

Prepared worksheets start with expected quantities filled in. Review the count before adding units, or explicitly set the physically counted total. Each intentional scan receives a new request token; retrying it returns the prior result without adding units twice. Scanner receipts retain the actor and result.

Scans change the draft worksheet only. Submitted, approved and rejected worksheets cannot be scanned or edited; rejected sheets must first be reopened. Submission and approval are audit records and do not change mirrored platform quantities. Legacy prepared comparisons can use Shopify totals across locations even when a worksheet has a location label; verify the exact pool before interpreting variance.

Label printing, camera decoding, offline scanning and scan-to-receive remain planned.

## Local stock reservations

Open **Stock → Reservations**, choose a specific source, location and catalog item, enter a positive whole-unit quantity and reference, then create the hold. Release it when no longer needed. Optional expiry removes it from active availability without a background job.

Available-to-promise uses the smaller of mirrored quantity and available quantity, floored at zero, minus active local holds for that exact pool. A Square hold cannot consume Shopify capacity or another location's capacity. Creation serializes within the pool before checking capacity.

External sales can reduce stock after a hold. Later imports can leave a pool overcommitted; review the mirror, active holds and exception queue before promising fulfillment. Rupert does not create platform reservations, consume a hold on fulfillment or apply a physical count to the mirror. Transfers, backorders and automatic allocation remain planned.

## Bulk lots and recipes

Open **Stock → Bulk materials**, create a material and record a lot receipt. Manual consumption or signed corrections require an operational reference. The ledger stores integer milligrams; entered g/kg/oz/lb weights use decimal conversion and round half-up once at the milligram boundary. Insufficient stock is rejected. Corrections append movements; prior movements are immutable through the application.

Open **Stock → Bulk recipes** to select an exact Shopify variant, one raw material, grams per sold unit and an effective timestamp with UTC offset. Grams support up to three decimal places. Each definition is an immutable version with a later effective time than its preceding version. Reused SKUs never choose a recipe.

Recipe selection uses the imported Shopify order creation time, not verified payment or production time. Verify delayed-payment, historical and edited orders before defining effective times. New versions change subsequent previews; recorded receipts retain their original version and weight.

## Reviewed sale material use

Open **Stock → Sale material use** and select 1–31 days of imported Shopify sales. Only confirmed complete, uncancelled, paid source snapshots with exact order/line/variant IDs and positive whole-unit quantities equal to the source's current quantities can be applied. Legacy, missing, truncated, quantity-reduced or refunded snapshots stay blocked. This gate does not prove that an order was never edited; verify the actual source sale before applying it. Existing snapshots become eligible only after a normal read-only import supplies the required source proof; old IDs are never guessed from a SKU.

Choose the actual lot used and select **Preview exact deduction**. The preview shows sold units, the effective recipe, required milligrams, current lot balance and any shortage. Confirm the source sale, recipe and actual lot before recording. A changed selection requires a new preview; reviews expire after 15 minutes and are bound to the reviewing user and store. Source details and lot capacity are checked again under lock.

Recording atomically creates one immutable receipt linked to one consumption movement. The external source order/line key prevents a second deduction even if local order-line rows are recreated. Concurrent requests cannot consume the same line or overdraw the selected lot. Changed source/recipe details require a separate reviewed material correction rather than rewriting history. The audit compares displayed receipts with the current imported source snapshot. Missing or changed source lines, quantities, payment/completeness or refund history are flagged for operator review, including when the line disappears from the sale list. This does not change the original receipt or restock raw material. Refunds do not automatically restock raw material.

This slice supports one material and one selected lot for a whole sale line. Splitting a line across lots, multi-material recipes, automatic consumption/refund reconciliation and source-stock writes remain planned.

The sale list filters imported order dates; its receipt CSV filters deduction-recording dates. Receipts include exact source IDs, lot, recipe version, milligrams, movement, time and actor. The complete bulk movement CSV also supports manual Google Sheets import. CSV export is not Google Sheets synchronization; an owner-selected destination and reconciliation contract remain pending.

## Mirror limits and physical verification

The queue evaluates stored Rupert records. Existing Shopify mirrors clamp negative source quantities to zero and can assign an aggregate quantity to the primary location when per-location data is unavailable. Catalog/location/level fetch limits can also omit source detail. A positive or zero mirror therefore cannot establish complete source coverage, detect every native oversold item or reconstruct a synthetic location allocation.

Stale snapshots, SKU-based historical estimates and legacy count sums require source and physical verification. Exact recipe consumption uses the separate bulk lot ledger; it does not reconcile these platform mirrors. No local workflow guarantees stock against concurrent external sales.

## Payment boundary

Valmar is the business-reported processor. Authorize.net is a possible gateway path, not a confirmed fact about this merchant account; other configured gateway choices require their own account confirmation. Rupert's credential/profile checks do not authorize, capture or refund payments or execute a terminal. Continue completing sales in the existing POS until the payment and operator cutover gates pass.

## Deployment

Run both adapter suites and review tenant isolation, source completeness, replay, concurrent deduction/mapping and reservation-capacity checks before promotion. Rehearse migrations on a private SQLite copy. Take a consistent backup, verify a separate restore, retain an Incus snapshot and migrate before starting the new code. Keep the SQLite single-worker default; greater concurrency requires measured evidence.

Retain recipe versions, material-use receipts, movements, reservations and explicit mapping decisions during rollback. Dropping tables discards business records. Never switch to the frozen PostgreSQL cutover database without reconciling subsequent SQLite writes.
