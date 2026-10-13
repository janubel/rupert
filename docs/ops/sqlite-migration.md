# Moving the live Rupert instance (SER8) from PostgreSQL to SQLite

Status: **DONE on SER8, 2026-10-13.** 78,573 rows in 61 tables copied with every count verified; the app runs on
SQLite (`/opt/rupert/web/storage/production.sqlite3`) and `rupert-backup.timer` snapshots it every 6 hours.
PostgreSQL on `rupert-db` still holds the pre-cutover data and was never modified, so rolling back is just removing
`RUPERT_DB_ADAPTER=sqlite3` from `/etc/rupert.env` and restarting.

### What the live run taught us
- Row-count verification caught a real bug the synthetic rehearsal could not: one row was dropped per 500-row batch
  (5 of 2,514 `InventoryLevel` rows). Fixed; the rehearsal now includes a 1,500-row table.
- In the `rupert` Incus container, `systemctl stop rupert-web` does not kill Puma (cgroup kill is denied and even root
  cannot signal the process), so restarts collide on port 3000. Stop the app by restarting the container from the
  host: `systemctl disable rupert-web; incus restart rupert; ...; systemctl enable --now rupert-web`.
  `cutover-ser8.sh` cannot do this from inside the container; use it only for the code phase.
  Root cause (confirmed on the `homeboard` container, 2026-10-13): the host's AppArmor denies `signal` from the
  container's current profile (`incus-<name>_</var/lib/incus>`) to processes that started under an older profile, so
  nothing inside the container can stop them. Symptoms: `Found left-over process ... in control group`, `Failed to kill
  control group ... Permission denied`, and a service in an endless `activating (auto-restart)` loop with
  `Address already in use` (Homeboard reached 18,899 restarts). Check with `incus exec <name> -- systemctl show <unit>
  -p NRestarts`, and on the host with `journalctl -k | grep 'apparmor="DENIED" operation="signal"'`. Any `systemctl
  restart` can trigger it after an Incus profile reload, so for `rupert-web` and `rupert-jobs` prefer
  `incus restart rupert` from the host. The data is on disk, so the restart costs only a short outage.
- The container had no job worker: scheduled syncs silently stopped after the 2026-10-02 container reboot and only
  resumed on 2026-10-13 once `deploy/rupert-jobs-ser8.service` was installed (`systemctl enable --now rupert-jobs`).
  Check `SolidQueue::Process.count` and the latest `SyncRun` after any container restart.
- Before this work the container had no database backup at all. It now has `/var/backups/rupert` (SQLite snapshots +
  settings + env copy) on a 6-hourly timer; copy that directory off the host periodically.

## What changed in the code

- `bin/rails db:postgres_to_sqlite` copies a PostgreSQL database into an empty SQLite one. It refuses a non-empty
  target, verifies row counts per table inside one transaction, rebuilds the FTS5 search indexes and reports foreign
  key problems that already existed in the source data.
- `bin/migrate-to-sqlite` wraps it: safety `pg_dump`, schema creation, copy, `PRAGMA integrity_check`.
- `bin/backup.sh` snapshots SQLite (`VACUUM INTO` + integrity check) when `RUPERT_DB_ADAPTER=sqlite3`.
- The app was already SQLite-capable (`config/database.yml`, backups in Settings, system page); the full test suite
  passes on both adapters.

## Before you start

1. Merge and deploy the code that contains these files to the Rupert container (deploying is a separate step from
   merging; see the README's Production section).
2. In the container: `apt install sqlite3`. Confirm free disk is at least twice the database size
   (`du -sh` of the Postgres data directory is a fine upper bound).
3. Keep the existing `.env`. The `RAILS_ENCRYPTION_*` keys must not change, because the settings table (Square and
   Shopify tokens) is copied as-is and decrypted with them.
4. Pick a quiet window. Sync is a read-only mirror, so a short outage loses nothing; the copy takes seconds to minutes.

## Cutover

```bash
# 1. stop the web server and the job worker (unit names are whatever the Incus container uses)
# 2. take the copy
./bin/migrate-to-sqlite
# 3. switch
echo 'RUPERT_DB_ADAPTER=sqlite3' >> .env
# 4. start web + jobs, then check:
#    - sign in, open Dashboard, Inventory, Customers (search), Sync
#    - Sync page: run one source sync and watch it finish
#    - Settings > Backup: download a snapshot
./bin/backup.sh     # confirms the SQLite backup path works on this host
```

## Rollback (any time)

Remove the `RUPERT_DB_ADAPTER=sqlite3` line from `.env` and restart. PostgreSQL still has all data up to the moment you
stopped the app. Anything written to SQLite after cutover is not carried back, so decide within the first day.
The safety dump `pre-sqlite-*.dump` in `/var/backups/rupert` can rebuild PostgreSQL if it is ever needed.

## After a week

- Make sure the timer-driven `bin/backup.sh` has produced SQLite snapshots (`rupert-*.sql.gz` now holds a gzipped
  `.sqlite3` file) and restore one on a scratch machine: `gunzip -c rupert-X.sql.gz > test.sqlite3`.
- Then retire PostgreSQL on the host and drop the `pg` dependency in a follow-up change.

## Known differences

- Search: PostgreSQL used `pg_trgm`; SQLite uses FTS5 trigram for terms of three or more characters.
- One writer at a time: SQLite is configured with WAL and a 5 s busy timeout. The sync and job worker use short
  transactions, so this is fine at current volume; raise `SQLITE_BUSY_TIMEOUT_MS` if you ever see lock errors.
- `System` page shows file size and pool data instead of `pg_stat_*` views.
