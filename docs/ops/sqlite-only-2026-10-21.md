# SQLite-only source qualification — 2026-10-21

Owner directive: Rupert supports SQLite only. This follows the recorded production cutover; it does not migrate or erase a live database.

## Source changes

- SQLite is the database for development, test, and production, with WAL and existing per-environment file settings. Unsupported adapter selectors and all nonempty `DATABASE_URL` values fail with configuration guidance.
- PostgreSQL driver/system packages, service/volume definitions, schema dump, SQL branches, conversion tools, and CI job were removed. The canonical schema is `web/db/schema_sqlite.rb`.
- Backups use SQLite snapshots; search uses FTS5/LIKE; diagnostics show available SQLite data. Job concurrency remains conservative.
- Compose migration/web/jobs share `/app/storage/production.sqlite3`. The migration preflight requires an existing SQLite-header file or explicit `RUPERT_INITIALIZE_DATABASE=1` for a fresh installation. Existing PostgreSQL volumes are not imported automatically; retain historical volumes and backups separately.
- Deployment gating requires SQLite CI. Refresh the installed autodeploy script separately as described in `deploy/ser8/README.md`.
- Dated cutover and test receipts remain historical evidence. Active setup/recovery docs and generated product pages describe SQLite only.

## Validation

In an isolated Ruby 4 container with synthetic test data and no PostgreSQL driver/service:

- Full Rails suite: 2,191 tests, 17,938 assertions, no failures/errors/skips; all 14 critical-file coverage floors passed.
- All 122 migrations from an empty SQLite file passed, including integrity, foreign-key and FTS checks. This verification now runs in CI.
- Fresh migration replay found an existing POS foreign key declared before its parent table existed; its declaration now follows parent-table creation, preserving the final schema.
- Existing warehouse hold/bank mapping migration verification, Tailwind and asset compilation passed.
- RuboCop: 1,031 files, no offenses.
- Deploy gating tests: 9 passed. Product-site consistency, documentation links and shell/Python syntax checks passed.
- Configuration/default-path rejection and Compose preflight tests cover missing/empty/non-SQLite files, explicit fresh initialization, and prohibited database overrides.

No host services, production database or old database volumes were changed during this source qualification. Host deployment and an isolated restore of the current off-host backup/keys remain separate operational acceptance steps.
