# Inventory workflow operations

These workflows record local work in Rupert. Shopify and Square remain independent inventory pools. Neither workflow pushes inventory, edits SKUs, settles payments or guarantees availability in another sales channel.

## Scanner counts

Open **Stock → Counts**, create or open a draft worksheet, and choose **Scan items**. A keyboard-wedge scanner enters a SKU or a barcode already stored in Rupert. Unknown or ambiguous codes need operator review; Rupert must not select the first matching item silently. The catalog importer currently imports SKUs, but does not populate the Shopify barcode field, so SKU scanning is the immediately supported workflow.

A prepared worksheet starts with the expected quantities filled in. Review the displayed count before adding units, or explicitly set the physically counted total. Scans change the draft worksheet only. Submit the worksheet through the existing approval flow when finished. Submission and approval remain audit records and do not change mirrored platform quantities.

Each intentional scan receives a new request token. Retrying the same request must return its prior result without adding units a second time. Scanner receipts retain the actor and result for audit. Submitted, approved and rejected worksheets cannot be scanned or edited; rejected sheets must first be reopened.

Label printing, camera decoding, offline scanning and scan-to-receive remain separate planned work.

## Local stock reservations

Open **Stock → Reservations**. Choose a specific source, location and catalog item, enter a positive whole-unit quantity and an operational reference, then create the hold. Release a hold when it is no longer needed. Optional expiry removes it from the active availability calculation without requiring a background job.

Available-to-promise uses the smaller of the latest mirrored quantity and available quantity, floored at zero, minus active local reservations for that exact pool. A Square hold never consumes Shopify availability, and a location's hold never consumes another location's availability. Creation is serialized within the pool before checking capacity, so simultaneous Rupert requests cannot both reserve the same last units.

External sales can still reduce stock. A later sync can therefore leave a pool overcommitted; review the on-hand, reserved and available values before promising fulfillment. Release or resolve holds operationally. Rupert does not create platform reservations, consume a hold on fulfillment or automatically reconcile a count against the mirror.

Transfers, backorders and automatic order allocation remain separate planned work. Inventory read permission is required to view the workflows; inventory write permission is required to change them.

## Deployment

Run both adapter test suites and review tenant isolation, replay handling and reservation capacity tests before promotion. Rehearse the migrations on a private SQLite copy. Take a consistent backup, verify a separate restore, retain an Incus snapshot and deploy the migrations before starting the new code. Keep the SQLite single-worker default; increasing worker concurrency requires measured evidence.

Rollback the application only after considering the new audit records and reservations. Retain the new tables and a consistent backup when rolling back code. Dropping tables would discard business records. Never switch back to the frozen PostgreSQL cutover database without reconciling all subsequent SQLite writes.

## Bulk materials

Open **Stock → Bulk materials**, create a material and record a lot receipt. Record consumption or signed corrections against that lot with an operational reference. The ledger stores integer milligrams; entered g/kg/oz/lb values use decimal conversion and round half-up once to the nearest milligram. Insufficient stock is rejected. Corrections append a movement; prior movements cannot be edited or deleted through the application.

Download the complete tenant movement CSV for manual Google Sheets import. It includes stable movement IDs, UTC times, entered units/weights, milligram changes and current lot balances, references and actors. This is an export, not a Sheets synchronization. Automatic product-to-gram mappings, sale/refund deductions, recipes and Google Sheets sync remain planned; duplicate or missing catalog identities must be resolved before automatic consumption.
