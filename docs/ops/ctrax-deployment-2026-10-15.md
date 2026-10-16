# C-Trax stock deployment — October 15, 2026

SER8 production was promoted from `032dc062ca796ecd997f07cc6cefedf4556f9fe0` to `a48a5977fde56b5892a594d4cd6a3a272c891e1e` at approximately 8:55 PM America/New_York. The source is [draft PR #44](https://github.com/techmore/rupert/pull/44), stacked on [count-comparison PR #42](https://github.com/techmore/rupert/pull/42). Neither PR was merged by this deployment.

The release adds encrypted C-Trax user setup, explicit login/merchant-list diagnostics, paginated native store/variant stock snapshots, physical-count/scanner support for missing SKUs, and an opt-in hourly production job. TRX merchant credentials remain separate from stock authentication. No payment or upstream stock writes were made.

## Validation and recovery

- Local SQLite: 844 tests, 6,167 assertions, zero failures/errors/skips. Configured Ruby lint and generated-site/link checks passed.
- Both push and PR CI matrices passed on SQLite and PostgreSQL; product-site consistency and CLA checks passed.
- An Incus recovery snapshot and consistent private database/config/service backups were retained on SER8 before promotion; a second consistent database backup was taken immediately before migration. Backup contents are not public.
- All four pending migrations were rehearsed against an isolated copy. Integrity and foreign-key checks passed, and all 105 prior tables retained their row counts. Assets compiled and Rails eager loading passed.
- Live migrations advanced to `20261015220000`; live integrity/foreign-key checks and eager loading passed. Activation used host-side `incus restart rupert`, following the existing AppArmor restart guidance.
- Public `/up` and `/login` returned 200. Web/jobs services and the backup timer were active, with zero restart counters. The checkout was clean.
- The hourly task was registered as `ctrax_stock`, class `CtraxStockSyncJob`, schedule `every hour at minute 20`; a fresh supervisor/dispatcher/worker/scheduler heartbeat was observed. Old process rows from before the container restart are not additional running workers.
- Production orders and Shopify variant counts were unchanged from the recovery baseline. The two pre-existing failed jobs remained unchanged. The requested owner account was created and audited; password sign-in and authenticated C-Trax setup/stock, Users, Permissions and Platform pages returned 200. Account-specific recovery details are private.

## Remaining activation gate

At verification, no production C-Trax connection had been saved and no live API stock snapshot had been imported. The owner must save an authorized C-Trax read account on the production setup page, check access and complete the first stock sync. Hourly scheduling remains inactive for that account until explicitly enabled. Do not describe the deployed worker as a verified live integration before a real import succeeds.

The connector follows an observed Serv 2.0 portal API contract. Supported partner API documentation/access remains under investigation. C-Trax sales, settlements, fees, fractional physical counting and upstream stock correction are separate work. A browser session and a dated CSV review export do not replace a server read account or a complete native-ID stock snapshot.

Rollback must preserve business writes made since deployment. Do not restore the older database over subsequent records automatically. The last pre-deployment release predates the warehouse-tier tenancy migration; use a schema-compatible tested release for a code-only rollback or reconcile data before any database restore.
