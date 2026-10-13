# Rupert changelog

## Unreleased

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
