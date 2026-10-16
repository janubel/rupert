# Dashboard source status and 30-minute reads

The dashboard displays C-Trax, SwipeSimple and Authorize.net separately, with their latest source-read timestamps and on-demand controls. A configured schedule does not establish fresh vendor delivery.

- C-Trax: approved saved credentials allow direct stock reads every 30 minutes. Manual reads can run while automatic stock reads are paused. Native variant IDs, signed stock and missing quantities are retained.
- SwipeSimple: every-30-minute local intake consumes newly delivered native transaction/invoice CSVs only when `RUPERT_SWIPESIMPLE_INBOX` is configured. On-demand intake is tenant-scoped. Without a supported producer, Sync now opens the native upload workflow, and the badge says Needs feed. The displayed source time is the export capture time, never the latest empty intake run.
- Authorize.net: approved API reporting connections run every 30 minutes when enabled. Existing merchant keys are sufficient where authorized; replacement is unnecessary for portal downloads. Without API access, the dashboard opens portal CSV imports and the merchant reporting page. Portal snapshots stay visibly distinct from API reconciliation.

## Native Authorize.net portal evidence

In Manage Transactions, choose Settled Transactions and the required date range, then download Expanded Fields/Comma Separated. Repeat for current Unsettled Transactions. Verify the numeric Gateway ID from the visible merchant profile. Supply each file's actual capture time with UTC offset.

The importer validates native transaction IDs, currencies, amounts, row widths, explicit source time zones, duplicate IDs, file bounds and active workspace. Entire files are validated before writes. Original CSV and normalized observations are encrypted; exact replays return their existing receipt. Source transaction ID plus Gateway ID identifies the latest observation across dated exports. Late older files cannot supersede newer evidence. No retail orders or API transaction records are created by portal imports.

Report access requires reports.read. Source imports, original documents and manual delivery checks require sync.write. Manual C-Trax additionally requires inventory.write; manual API reporting requires settings.write. Original CSV downloads remain tenant-scoped and private.

The portal page shows totals only for the verified native Authorization w/ Auto Capture type with Settled Successfully status, grouped by currency. Declines, errors, pending payments, refunds and other unverified types are excluded. A CSV export is a dated snapshot of the selected window, not proof of complete account history or automatic access.

## Production scheduling

Use the existing Solid Queue worker/scheduler and config/recurring.yml; all three source tasks use every 30 minutes. The historical database flag hourly_sync_enabled now gates the C-Trax 30-minute schedule. Missing credentials or a missing CSV delivery directory keep that source inactive. Existing IRIS, Shopify, Square and operations schedules retain their own settings.

Before release, back up production SQLite/config, rehearse the additive portal-export migration and check every existing table count. Restart the existing application container after promotion. Verify the recurring task rows, a real C-Trax worker completion, source timestamps, duplicate replay, encrypted originals, tenant permissions and public health.
