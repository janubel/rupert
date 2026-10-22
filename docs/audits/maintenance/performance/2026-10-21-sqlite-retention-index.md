# Performance maintenance audit — 2026-10-21

## Scope and branch audit

Reviewed the repository guidance, current default branch, recent SQLite receipts, current source and active PRs before changing files. The shared checkout was on the separate `rust-core` branch; that branch was not used as a base. The remote identifies `origin/main` as both HEAD and the default branch. The isolated review branch `codex/performance-audit-20261021` starts at `origin/main` commit `3fd1d0ad8f940bc18e49da4cf536e24bb781fa71`.

Current `main` identifies the active application as Rails 8.1 with SQLite as its only supported adapter. Its SQLite configuration uses WAL, `synchronous=NORMAL`, a 5-second busy timeout, and one default job thread. The October 21 SQLite-only audit records fresh SQLite migration and test validation; earlier PostgreSQL support/test statements on the preexisting `rust-core` checkout are stale for current `main`. The October 14 performance receipt already covers the earlier inventory N+1/cache fix and sync/customer indexes; this audit does not repeat those changes.

The code and operating evidence describe separate delivery states:

- Rails is the established web application on the Rupert host. The October 20 production-readiness audit records `/up` HTTP 200 and live build `4e45c061…`; the later October 20 read-only time-records audit inspects production revision `bbf367de` at 23:30 EDT. The October 17 deployment/recovery receipt records release `96da4700b2ac3c05ee7b2aaa3f4ae1e23057d019`; the October 20 read-only revision is newer evidence than that deployment receipt. The separate October 20 Projects readiness review could not establish trusted HTTPS from its review host, which does not establish that the service was down. None of these dated records proves that reviewed `main` (`3fd1d0a` at branch creation) was deployed. No live endpoint or production table metrics were queried by this run.
- Rust core is not part of current `main`: PR #163 added it and PR #176 removed `core/` and its workflow on October 19. The remaining code is on `origin/archive/rust-core`; its October 17 deployment record says build `27fcd16` was deployed to a separate `rupert-core` container for a read-only shadow mirror. Its October 18 unattended check recorded healthy scheduled syncs and parity with the Rails mirror. The same records leave public DNS/Caddy routing, webhook registration and route cutover open. This is separate shadow deployment evidence, not acceptance of Rust as the primary Rupert application.
- `mobile/` is employee-client source. Its README records CI JavaScript exports, not a signed IPA/APK; account setup, signing, store submission and real-device acceptance remain pending.

Open PRs and active worktrees were inspected before editing. Current open PRs include #295 (production logging), #299 (upload quota serialization), #300 (mobile SDK compatibility), and #301 (local-model bake-off), among others. None changes inventory retention. Work was kept in a new worktree; no existing worktree or branch was edited. The latest `main` CI run was still in progress during the audit; its Pages and Security jobs had completed successfully. The previous run at `3c43f62` had completed CI, Pages and Security successfully.

After the isolated branch was created, `main` advanced from `3fd1d0a` through documentation-only PR #311 (`96d8776b`). Its updated SQLite runbook and maintenance receipt were reviewed, and the PR branch was refreshed to include that base commit.

## Ranked findings

1. **Measured source improvement: tenant-scoped inventory-movement retention.** `DataRetention.prune` selects old IDs using the current tenant scope and a timestamp predicate in 5,000-row batches. `InventoryMovement` has an index on `tenant_id`, a separate index on `createdAt`, and `(tenant_id, source, createdAt)`, but no index for the actual `(tenant_id, createdAt)` predicate. The selected change replaces the narrower tenant-only index with `(tenant_id, createdAt)`. The new leading tenant column continues to support tenant-only lookups, while the date column lets SQLite seek the retention range. SQLite's [query-planner documentation](https://www.sqlite.org/queryplanner.html#multicolidx) describes this multi-column index behavior.
2. **Keep current SQLite operating limits.** No observed production backlog, busy-error count, full-import timing, request latency, or memory series was available. The existing one-thread job default and SQLite choice remain appropriate; this audit has no evidence to increase concurrency, split the queue database, or replace SQLite.
3. **Separate deployed and accepted versions from source.** Main CI success and Pages publication do not establish that current Rails source is deployed or accepted. The latest dated Rails production evidence is build `4e45c061…` in the October 20 audit, older than the reviewed `main` head. The Rust shadow application has separate deployment records; mobile builds remain unsigned and unaccepted. Release and restore acceptance belongs to task 06.

## Synthetic measurement

The bounded benchmark used fresh temporary SQLite databases with WAL and `synchronous=NORMAL`, then measured the exact batched ID-selection and delete shape used by retention. It used Python 3.14.4 with SQLite 3.46.1; it did not use production data. Each variant had five independently-created 240,000-row database trials. The table included the current separate timestamp index and tenant/source/timestamp index. Seventy-five percent of rows belonged to the target tenant; 30,000 target-tenant rows and 30,000 other-tenant rows were older than the cutoff; 150,000 target-tenant rows were newer. Batch size was 5,000.

| Metric | Existing indexes | Replace tenant index | Result |
| --- | ---: | ---: | --- |
| Prune duration, median of five full runs | 235.95 ms | 153.22 ms | 35.1% lower |
| Run times | 254.58, 235.95, 247.02, 226.95, 228.30 ms | 153.22, 152.54, 174.36, 153.37, 149.15 ms | Same six batches |
| Query plan | `tenant_id` index, then timestamp filtering | `(tenant_id, createdAt)` range lookup | Avoids scanning fresh rows for the tenant |
| Correctness | 30,000 target rows deleted; 30,000 old other-tenant rows and 150,000 fresh target rows remain | Same | No cross-tenant or fresh-row deletion |

A separate write/storage probe used five batches of 2,000 inserts after loading 120,000 synthetic rows, across three fresh databases per variant. Median insert-batch duration was 6.66 ms with the existing indexes and 7.23 ms after replacing the tenant index (+0.57 ms, 8.6%). Median total database size was 18.39 MiB and 20.79 MiB (+2.40 MiB, 13.1%). These are bounded local costs, not production-scale projections. A simpler add-only candidate increased storage and write cost more, so it was rejected in favor of replacing the tenant-only index.

The benchmark measures only this retention query and synthetic inserts. It does not measure HTTP p50/p95, memory, complete provider imports, real SQLite 3.53.2 production behavior, WAL contention under application load, or production throughput. Absolute prune savings are under 100 ms for this synthetic workload. The source change is therefore a small maintenance-query improvement, not a claim of material customer-visible latency improvement.

## Change and checks

The source change adds one reversible migration replacing `InventoryMovement(tenant_id)` with `InventoryMovement(tenant_id, createdAt)` and updates the canonical SQLite schema dump. It preserves tenant scoping, batch size, retention windows, WAL settings, and all business data semantics.

Checks run in an isolated Ruby 4.0.6 Alpine container with a temporary SQLite test database and synthetic test fixtures:

- `bin/rails db:prepare` applied the migration successfully. SQLite reported the new index; the migration's `remove_index` operation also completed.
- `bin/rails test test/services/data_retention_test.rb` — 5 runs, 16 assertions, 0 failures/errors/skips, including old/fresh row handling and tenant isolation.
- RuboCop on the migration — no offenses.
- The direct SQLite benchmark verified query plans, batch count, deleted-row count, retained tenant rows, insertion timing and database bytes.
- `git diff --check` passed after editing.

No production database, schema, credentials, services or source platforms were accessed or changed. No live provider calls, deployment, route/auth changes, job retries, backfills, or production maintenance operations were performed. The PR is source-only pending review, merge, release and operator acceptance.

## Next iteration

Task 06 should compare this migration against an authorized, isolated copy of the current production SQLite database and its actual `InventoryMovement` row count/write rate before release acceptance. Re-measure retention and insertion overhead on that copy, then follow the established backup/restore gate; do not treat this synthetic result as deployment approval.
