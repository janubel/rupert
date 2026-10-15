# SQLite and Incus operating decision — 2026-10-14

## Decision and evidence

Keep Rupert as a Rails modular monolith in an unprivileged Incus system container on SER8, with SQLite on local persistent storage. The [cutover report](https://github.com/techmore/rupert/blob/main/docs/ops/sqlite-migration.md) records a completed 2026-10-13 migration: 78,573 rows in 61 tables, counts verified, a worker installed and six-hourly snapshots configured. The cutover counts are historical. A fresh live check on October 14 confirmed SQLite 3.53.2, healthy web/jobs, the one-thread worker default, and a verified local backup restore; see the [deployment receipt](https://github.com/techmore/rupert/blob/main/docs/ops/deployment-2026-10-14.md). Production load and off-host recovery remain unmeasured. The code still defaults to PostgreSQL so existing development/CI users do not silently switch adapters; production selects SQLite explicitly.

GitHub Pages publishes product documentation only. It cannot host Rails, jobs or a writable SQLite database. A push/release does not deploy the ERP or change its live environment.

## Configuration and optimization

Set these in the existing root-protected `/etc/rupert.env` after checking the active configuration:

```dotenv
RUPERT_DB_ADAPTER=sqlite3
RUPERT_SQLITE_DATABASE_PRODUCTION=/opt/rupert/web/storage/production.sqlite3
SQLITE_BUSY_TIMEOUT_MS=5000
RAILS_MAX_THREADS=5
JOB_CONCURRENCY=1
JOB_THREADS=1
```

The application already sets WAL, synchronous=NORMAL and FTS5 trigram search. This change defaults SQLite job workers to one thread (PostgreSQL stays at three); `JOB_THREADS` allows an explicit override. Queue tables and business data currently share a database. Serializing worker threads reduces simultaneous writers but does not eliminate web-versus-job contention; measure job delay before increasing concurrency or splitting the queue database.

[SQLite WAL](https://www.sqlite.org/wal.html) permits concurrent readers with a single writer and requires same-host shared memory. Store the database and its WAL/SHM alongside it on a local Incus volume, not NFS/SMB. NORMAL can lose recent committed transactions during power loss; FULL is the durability alternative, with a write-latency cost. Choose from measured latency and the acceptable recovery point, not from a speed claim. Check the linked upstream page for patched SQLite versions, including its WAL-reset bug advisory; the diagnostic reports the library actually loaded by Ruby.

Run as the existing application user, in `/opt/rupert/web`, with its normal production environment loaded:

```bash
bundle exec bin/rails ops:sqlite:report
bundle exec bin/rails ops:sqlite:optimize
```

The report reads adapter/version, PRAGMAs, page/free space and WAL size without exposing business records. Optimize explicitly runs `PRAGMA optimize=0x10002` to refresh useful planner statistics in a short-lived connection. Modern SQLite bounds this work; check the deployed library version before scheduling. It changes planner metadata, not business rows. Schedule daily during a quiet interval only after measuring runtime; this change does not install a live timer. [PRAGMA optimize documentation](https://www.sqlite.org/pragma.html#pragma_optimize).

Keep write transactions short. Do API/network work before entering write transactions. Prefer tenant-scoped pagination and existing composite indexes; use `EXPLAIN QUERY PLAN` on real slow queries before adding indexes. Preserve the existing FTS5 path for three-or-more-character substring search and test two-character fallback separately. Do not run blanket VACUUM or forced TRUNCATE checkpoints on every request.

## Measurement and release gates

Capture a baseline and candidate on the same sanitized snapshot and SER8 allocation. Exercise dashboard, location inventory, customer/SKU search, receiving and sync concurrently. Record p50/p95 request duration, sync duration, oldest ready job, failed-job count, SQLite busy errors, RSS, database/WAL bytes and query plans. Proposed initial gates: no errors or row-count drift; no more than 10% p95 or sync-duration regression; sync finishes before the next 15-minute schedule; backlog drains; no persistent WAL growth across two idle intervals. These are acceptance targets, not measured results.

CI must pass on both database adapters. Before production promotion, make a fresh consistent backup, restore into an isolated instance, check `PRAGMA integrity_check`, foreign-key exceptions against a known baseline, row counts and tenant-scoped business totals. Smoke-test login, inventory/search, read-only sync and a downloaded backup. Never test production credentials in CI.

## Incus operations and recovery

Use the SER8-specific units in `deploy/rupert-jobs-ser8.service`, `deploy/rupert-backup-ser8.*`, and `deploy/ser8/` rather than old droplet units. Keep web and jobs under a non-root app user, secrets root-readable, persistent data outside disposable release directories, and the public entry point behind the existing TLS proxy. Snapshot the instance before promotion; a crash-consistent instance snapshot complements an application-consistent SQLite backup.

The cutover report documents AppArmor signal denials after profile changes: systemd could not kill older Puma processes, leaving port 3000 occupied. Inspect host kernel denials and service restart counts. Until the host policy issue is resolved, use the documented host-side Incus restart procedure, followed by web, worker heartbeat, sync freshness and backup-timer checks. Do not disable AppArmor or make the container privileged as a workaround. [Incus security model](https://linuxcontainers.org/incus/docs/main/explanation/security/).

Six-hour local backups alone imply up to six hours of recovery-point exposure, and no host-loss recovery without off-host copies. Verify the actual timer and copy encrypted backups off SER8; restrict access because the backup includes environment/settings. Rehearse a restore and record measured recovery time before declaring disaster recovery complete.

The retained PostgreSQL database is frozen at cutover. Switching back would discard every subsequent SQLite business write unless those changes are migrated. Roll back code against the current SQLite database when compatible. A database rollback after new writes requires an explicit reconciliation/export plan; do not simply unset the adapter.

## Alternatives and triggers

| Option | When it is better | Cost / condition |
| --- | --- | --- |
| SQLite + Incus (chosen) | One host, modest write concurrency, simple operation | One writer; monitor busy errors/backlog and keep WAL local |
| PostgreSQL + Incus | Sustained writer contention, multiple app hosts, heavier reporting | More memory/operations; migrate and verify all writes since cutover |
| Separate SQLite queue DB | Jobs dominate business DB lock waits | New queue connection/schema and restore coordination; benchmark first |
| Incus VM | Stronger kernel isolation or persistent container policy constraints | More memory and guest administration; a VM does not remove SQLite writer limits |
| Docker inside Incus | Reproducible image releases become the main operational need | Nested runtime/storage complexity; no evidence of a present performance advantage |
| Odoo / ERPNext / Dolibarr | Broad standard ERP modules matter more than custom Rails workflows | Data migration, connector fit and operating/training costs; compare the functionality matrix |

[SQLite's deployment guidance](https://www.sqlite.org/whentouse.html) supports an application-server database but recommends a client/server engine when many concurrent writers or multiple networked database clients become necessary. Incus remains a reasonable host for either database. There is no measured reason in this review to replace it.
