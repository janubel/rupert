# Rupert changelog

## Unreleased

- Keep the platform-reported Shopify quantity (`InventoryLevel.sourceQuantity`) next to the clamped mirror count so oversold stock is visible; the clamped `quantity` and every existing reader are unchanged. Also regenerate `db/schema_sqlite.rb`, which was missing the per-tenant `WarehouseTier.tenantId` column.
- Follow Shopify variant, location and per-item inventory-level connections to exhaustion so products with more than 100 variants or stores with many locations are no longer silently truncated.
- Correct inventory stock-map caching across searches and batch variant loading to remove per-product queries.
- Add measured tenant timeline indexes for the last-sync lookup and customer list, with stable customer pagination for timestamp ties.
- Publish isolated SER8 SQLite read/write, inventory-query and WAL contention measurements with reproducible research harnesses.

- Publish a shared 49-feature catalog, delivery roadmap and sourced 14-competitor / 32-capability matrix on GitHub Pages, with search filters and CSV/JSON downloads.
- Add the signed-in Features & roadmap page and SQLite configuration, library and WAL diagnostics on System health.
- Add explicit SQLite planner maintenance tasks and a one-thread SQLite worker default, configurable with `JOB_THREADS`.
- Reconcile documented SER8 SQLite cutover status, fix unsafe stale-database rollback guidance, and document Incus recovery, backup checks and scaling alternatives.
- Check generated site consistency and local documentation links in CI.

- Add `db:postgres_to_sqlite` and `bin/migrate-to-sqlite` to copy a live PostgreSQL database into SQLite with verified
  row counts, and SQLite support in `bin/backup.sh`. Runbook: `docs/ops/sqlite-migration.md`.
- Reorganize `docs/` (plans, research, audit data, index) and remove dead scaffolding (`.gitmodules`, empty `extensions/`).
- UI: shared `.page-title`, `.empty-row` and `.flash` components, skip-to-content link, `main` landmark target.

## 0.2.0 — 2026-10-03

- Add opt-in SQLite support with FTS5 trigram search for local performance evaluation. PostgreSQL remains the production default.
- Cache global search results by tenant, user, and HR permission so results cannot cross tenant boundaries.
- Update Rails to 8.1.4, Shopify CLI to 4.8.4, and compatible patch/minor Ruby dependencies.
- Repair the CI workflow so the repository's tracked lockfiles no longer stop checks before they run.
- Require an explicit PostgreSQL password in the optional Docker Compose and backup paths; remove the unsafe `rupert` password fallback.
- Update deployment documentation to reflect the live SER8/Incus host and mark legacy systemd instructions as outdated.

## 0.1.0

- Initial Rupert application release.
