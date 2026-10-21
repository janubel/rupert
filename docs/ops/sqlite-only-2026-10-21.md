# SQLite-only audit follow-up — 2026-10-21

PR #267 removed PostgreSQL support and made SQLite the only adapter. This follow-up preserves that change and its canonical `web/db/schema.rb` while closing gaps found during independent validation.

## Added protections

- Unsupported legacy adapter settings and every nonempty `DATABASE_URL` fail with guidance to use the per-environment `RUPERT_SQLITE_DATABASE_*` file settings.
- Compose migration/web/jobs share `/app/storage/production.sqlite3`. Migration preflight requires an existing SQLite-header file or explicit `RUPERT_INITIALIZE_DATABASE=1` for a fresh installation. Existing volumes are not imported automatically; retain historical volumes and backups.
- The production image explicitly creates and owns its persistent storage directory before switching to the app user.
- SQLite diagnostics omit unsupported query/lock metrics rather than displaying empty PostgreSQL counters.
- Obsolete adapter branches in migrations are removed. Fresh replay found an existing POS foreign key declared before its parent table; its declaration now follows parent-table creation, preserving the resulting schema.
- CI verifies every migration against a fresh isolated SQLite file, including integrity, foreign keys and FTS. Active setup/recovery guides and generated pages reflect the current source.

## Validation

The combined source, including PRs #224, #265, #266 and #267, passed in an isolated Ruby 4 container with synthetic data and no PostgreSQL driver/service:

- 2,191 Rails tests, 17,938 assertions, no failures/errors/skips; all 14 critical-file coverage floors met.
- All 122 migrations from an empty SQLite file, with integrity, foreign-key and FTS checks.
- Configuration/default-path rejection and synthetic preflight tests for valid, missing, empty and non-SQLite files plus explicit fresh initialization.
- RuboCop: 1,031 files, no offenses.
- Fresh schema setup, warehouse hold/bank mapping verification and asset compilation also passed during the audit.

GitHub protection already requires SQLite CI, product-site consistency, security/static scan and CLA, with up-to-date branches; the retired PostgreSQL check is absent.

No host services, production database or historical database volumes were changed. Refresh copied deployment scripts separately and verify an isolated restore from the current off-host backup with its keys before claiming operational recovery acceptance.
