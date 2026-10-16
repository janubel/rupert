# Dashboard source status and scheduled reads

The dashboard displays C-Trax, SwipeSimple, Authorize.net, Shopify, NAB/IRIS and platform Google Drive backup separately, with their source-read timestamps. The credentials hub adds acquisition receipts, queue state and worker evidence. A configured schedule does not establish fresh vendor delivery. See the [live source audit](live-sync-audit-2026-10-16.md) for the October 16 checkpoint.

- C-Trax: approved saved credentials allow direct stock reads every 30 minutes. Manual reads can run while automatic stock reads are paused. Native variant IDs, signed stock and missing quantities are retained.
- SwipeSimple: approved encrypted website credentials and the existing `reporting_enabled` opt-in allow native transaction/invoice website reads every 30 minutes. Each read starts an independent login session and validates account identity, both export kinds and complete row counts. Identical bytes retain the existing original; the connection records the fresh validated read time. This website flow is separate from a supported reporting API or vendor-delivered feed, which remains unverified. The legacy CSV inbox needs `RUPERT_SWIPESIMPLE_INBOX` and an approved producer; it remains disabled on SER8. Do not enable that inbox merely because website reads work. See [research and support limits](swipesimple-integration-research.md).
- Authorize.net: approved API reporting connections run every five minutes when enabled. Merchant portal login does not establish API entitlement. Use the intended reporting credentials without rotating shared checkout keys. Without API access, portal CSV imports remain manual dated evidence, distinct from API reconciliation.

## Native Authorize.net portal evidence

In Manage Transactions, choose Settled Transactions and the required date range, then download Expanded Fields/Comma Separated. Repeat for current Unsettled Transactions. Verify the numeric Gateway ID from the visible merchant profile. Supply each file's actual capture time with UTC offset.

The importer validates native transaction IDs, currencies, amounts, row widths, explicit source time zones, duplicate IDs, file bounds and active workspace. Entire files are validated before writes. Original CSV and normalized observations are encrypted; exact replays return their existing receipt. Source transaction ID plus Gateway ID identifies the latest observation across dated exports. Late older files cannot supersede newer evidence. No retail orders or API transaction records are created by portal imports.

Report access requires reports.read. Source imports, original documents and manual delivery checks require sync.write. Manual C-Trax additionally requires inventory.write; manual API reporting requires settings.write. Original CSV downloads remain tenant-scoped and private.

The portal page shows totals only for the verified native Authorization w/ Auto Capture type with Settled Successfully status, grouped by currency. Declines, errors, pending payments, refunds and other unverified types are excluded. A CSV export is a dated snapshot of the selected window, not proof of complete account history or automatic access.

## Production scheduling

Use the existing Solid Queue worker/scheduler and `web/config/recurring.yml`. C-Trax stock and SwipeSimple website reads run every 30 minutes; C-Trax sales run at minutes 5 and 35. The historical database flag `hourly_sync_enabled` gates C-Trax stock. Shopify/catalog scheduling runs every 15 minutes; Square is included only when its access token is configured. Authorize.net reporting dispatches every five minutes. NAB native deposits run daily at 06:45 Eastern, platform backup every six hours, directories every 30 minutes and document-retention Drive every 15 minutes. Dispatch registration does not mean a connection is enabled or authorized. Missing credentials, disabled opt-ins and the absent CSV inbox remain inactive; preserve these settings while diagnosing.

Before release, back up production SQLite/config, rehearse the additive portal-export migration and check every existing table count. Restart the existing application container after promotion. Verify the recurring task rows, a real C-Trax worker completion, source timestamps, duplicate replay, encrypted originals, tenant permissions and public health.
