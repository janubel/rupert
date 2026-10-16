# Rupert core (Rust) — spec, branch `rust-core`

Status: **spike, not parity.** The Rails app in `web/` stays the product until
this branch reaches feature parity. Priorities, in order: performance, memory,
storage, then developer speed. Nothing here writes to Shopify or Square (see
`AGENTS.md`: always ask the owner first).

## Why a separate core

Rupert is ~22.5k lines of Ruby, 65 controllers, ~93 tables. A big-bang rewrite
is the risky path, so the plan is a **strangler**: the Rust core takes over the
hot paths first (tenant routing, inventory reads/adjusts, sync ingest,
realtime feed, reporting) behind the same API (`docs/api-v1.md`), route by
route, while Rails keeps the rest. Parity is measured per route.

## Stack decision (provisional — confirm with the benchmark below)

| Layer | Choice | Why |
| --- | --- | --- |
| HTTP | axum on tokio, HTTP/1.1 first | mature, small, fast; h2/h3 at the Caddy edge |
| Storage (OLTP) | SQLite, one file per tenant (WAL) | physical isolation, trivial backup/export/delete, tiny RSS |
| Central | one SQLite file: tenants, domains, users, memberships, invites, shares | small, hot, cached |
| Drivers | rusqlite (bundled), read pool + single writer per tenant | WAL gives concurrent readers; one writer avoids lock thrash |
| Cache | moka, idle-evicting open-tenant cache | memory is bounded regardless of tenant count |
| Migrations | embedded list, `PRAGMA user_version` per file | same runner for central and every tenant file |

Go was considered: equally capable for this load and shares tm-remote's stack,
but Go is not installed on the build machine and the owner prefers Rust for the
memory/storage goals. Rails stays for the admin UI until replaced.

### Database alternatives (why SQLite stays the system of record)

Requirement: realtime + reporting, still a database. Keep one OLTP engine and
add purpose-built read paths instead of swapping the core:

- **Realtime:** the `movements` table is an append-only outbox. A per-tenant
  broadcast channel pushes new rows to SSE/WebSocket clients; clients resume
  from a last-seen `id`. No broker needed.
- **Reporting:** run analytics in **DuckDB** (embedded, columnar) reading
  tenant snapshots or Parquet exports, never against the live OLTP file.
- **Evaluate, don't adopt blindly:** Turso/libSQL (SQLite-compatible, Rust),
  Postgres (only if one shared multi-writer DB is ever needed), embedded KV
  stores such as redb/fjall (fast, but lose SQL, tooling and Litestream). A
  `Storage` trait boundary keeps a swap possible; any candidate must beat the
  SQLite numbers below on the same workload before it is considered.

## Tenancy model

Tenant = organization. Shops, domains, users, memberships (owner/manager/staff,
scoped to org or shop), invites and cross-org shares live in the central DB.
Business data lives in `tenants/<id>.db`. Host header -> tenant via a cached
`domains` lookup (negative results cached). Cross-org sharing is by explicit,
revocable grants over the API, never by joining databases. Provider tokens are
encrypted with a per-tenant key. Hard-isolation tenants can later move to their
own Incus container with the same binary and one data directory.

## Performance budget (targets, to be verified)

- p99 under 5 ms for indexed reads, under 10 ms for adjusts, on loopback.
- Idle RSS under 30 MB with the open-tenant cap applied; no per-tenant growth
  beyond the cap.
- Storage: no ORM metadata, `WITHOUT ROWID` where keys are natural, one WAL
  per open tenant. Measure bytes per item.
- No unbounded queues; backpressure by returning 503, not buffering.

## Operations

Litestream (or periodic `VACUUM INTO`) per tenant file; `sqlite3` CLI for
support; one migration runner; one static binary.

## Milestones

1. Spike (this commit): tenancy core, inventory read/adjust, benchmark.
2. Auth: sessions, memberships, invites, API tokens compatible with Rails.
3. Sync ingest (read-only mirrors of Shopify/Square) + SSE feed.
4. Reporting via DuckDB snapshots.
5. Route-by-route parity against `docs/api-v1.md`, then flip the proxy.

## Spike measurements (2026-10-16)

Setup: one binary, A/B by env vars (`RUPERT_CACHE_KB`, `RUPERT_MMAP_MB`,
`RUPERT_READERS`, `RUPERT_GROUP_COMMIT`, `RUPERT_MAX_OPEN`). 500 tenants x 2000
items seeded once and copied fresh for every config. Per config: 500 tenants
touched, then 5 runs x 6 s of `oha` at 32 connections for reads (hot tenant,
indexed lookup) and for adjusts (hot tenant, single hot SKU, the worst case for
a single writer). Numbers are **medians of 5 runs**. Loopback only; the load
generator shares a 10-core Asahi laptop that was also running a desktop session
(`nice 19`), so absolute numbers will differ on a server. No Rails comparison
was measured; the memory advantage over Ruby is expected but unverified.

| Config | RSS after 500 tenants | Read rps / p99 | Write rps / p99 |
| --- | --- | --- | --- |
| baseline (cache 2 MB, mmap 16 MB, 4 readers, no group commit, 256 open) | 75 MB | 25.1k / 6.4 ms | 13.8k / 10.1 ms |
| + group commit only | 73 MB | 29.1k / 4.9 ms | 52.3k / 3.0 ms |
| + small caches, mmap 0, 2 readers, 64 open | 32 MB | 12.7k / 9.7 ms | 67.3k / 2.7 ms |
| reader pool 8 (current default) | 34-35 MB | 97.2k / 1.95 ms | 53-54k / 3.1-3.3 ms |

Findings:
- **Group commit** (one leader drains all queued adjusts into one transaction)
  is the write win: about 4x throughput and p99 10 ms -> 3 ms.
- **Memory** is dominated by per-connection page cache times open tenants.
  Cache 512 KB, no mmap and a 64-tenant open cap cut RSS from 75 to ~34 MB
  after touching all 500 tenants; idle RSS is 5 MB.
- **Reader pool size is a throughput cliff**: a pool smaller than the request
  concurrency reopens connections constantly (reads fell to 12-25k rps). 8
  readers gave ~97k rps. The pool should be sized from measured concurrency,
  or replaced by per-thread connections.
- Targets met on this setup: read p99 < 5 ms, adjust p99 < 10 ms, idle RSS
  < 30 MB. Peak RSS under load was 55-58 MB (not budgeted yet).

Known limits of this spike: single tenant per load run (no mixed-tenant
traffic), no auth, no TLS, no SSE feed, no checkpoint tuning, WAL growth under
sustained writes unmeasured, a failing item in a batch fails the whole batch.
Storage was ~64 MB for 500 tenants x 2000 items including WAL (rough, not a
per-row figure).
