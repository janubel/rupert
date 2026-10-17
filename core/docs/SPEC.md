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

## Milestone 2: auth, memberships, invites, API tokens (2026-10-16)

Implemented in `src/auth.rs`, central migration 2 in `src/migrate.rs`,
black-box test in `tests/smoke.py` (41 checks, all passing; run
`python3 -I tests/smoke.py`).

- **Signup** (self-service): creates user, tenant, `<subdomain>.<RUPERT_BASE_DOMAIN>`
  domain and an owner membership in one transaction, returns a session.
- **Passwords:** Argon2id (19 MiB, t=2, p=1), concurrency capped (default 2)
  so a login burst cannot inflate RSS; unknown users are verified against a
  dummy hash so timing does not reveal accounts. One verify measured ~18 ms.
- **Sessions:** `rsess_` secrets, SHA-256 digest stored, 14-day expiry,
  HttpOnly + SameSite=Lax (+ Secure unless `RUPERT_COOKIE_SECURE=0`), tenant
  chosen by Host and checked against a membership.
- **API tokens:** same format as Rails (`rupert_` + 43 base64url chars,
  SHA-256 digest, shown once). Scopes: `catalog:read`, `inventory:read`,
  `inventory:write` (new), `roadmap:read`. Tokens carry their tenant; the Host
  header cannot change it. Effective rights = token scopes AND the owner's
  current role. Tokens cannot mint tokens or invites. Revocation invalidates
  the principal cache immediately (single process).
- **Roles:** owner > manager > staff. Managers invite staff and create tokens;
  only owners invite managers; nobody can mint an owner via invite.
- **Invites:** `rinv_` secret, digest stored, 7 days, single use (claimed
  atomically); an existing account must supply its password to accept.
- **Abuse limits:** in-memory per-IP and per-email limits (signup 5/min,
  login 20/min per IP and 10/min per email, accept 10/min). Behind a proxy set
  `RUPERT_TRUST_PROXY=1` (uses the rightmost `X-Forwarded-For`).
- **Audit:** signup, login, failed login, token create/revoke, invite
  create/accept are recorded in the central `audit` table.
- **Dev seed** (`/dev/seed`, deterministic tokens) only exists when
  `RUPERT_DEV=1`; otherwise it returns 404.

Cost of auth on the hot path (same benchmark as above, medians of 5 runs,
bearer token per request, principal cache with 5 s TTL):

| Run | RSS after 500 tenants | Read rps / p99 | Write rps / p99 |
| --- | --- | --- | --- |
| auth on, run 1 | 40 MB | 100.8k / 1.95 ms | 82.3k / 2.13 ms |
| auth on, run 2 | 40 MB | 99.2k / 1.98 ms | 75.2k / 2.23 ms |

Authentication added no measurable read cost (the earlier unauthenticated
default was 97k rps). Write throughput came out higher than before; I have not
isolated why (run-to-run noise and the removed Host-to-tenant lookup are both
candidates), so do not read it as an auth speed-up. RSS is ~5 MB higher than
without auth, partly the principal cache and Argon2 state. Peak RSS with a
fresh server and one login was 26 MB.

Not done / known gaps: no password reset or email verification, no TOTP/MFA
(needed before multi-customer hosting and for PCI-adjacent operator access),
no bcrypt import of Rails password digests, role/ownership changes are not
exposed (cache TTL 5 s applies if added), rate limits are per process, no
CSRF token beyond SameSite=Lax plus JSON-only bodies, `catalog:read` and
`roadmap:read` endpoints do not exist yet, and the invite token is returned to
the inviter instead of emailed.

## Milestone 3: read-only mirror sync + realtime feed (2026-10-16)

Code: `src/upstream.rs` (clients + allowlist), `src/sync.rs` (connections, sync
runs, ingest, mirror reads), `src/feed.rs` (outbox + SSE), `src/crypto.rs`
(sealed credentials), tenant migration 2. Tests: `cargo test` (4 unit tests:
sealing, GraphQL mutation guard, Square allowlist, shop-domain validation),
`tests/smoke.py` (41 checks) and `tests/sync_smoke.py` (44 checks against mock
Shopify and Square servers; 12 of 12 consecutive clean runs after the fix below).

**Nothing writes to Shopify or Square.** The Shopify client rejects any GraphQL
containing `mutation`/`subscription`; the Square client only allows
`GET /locations`, `GET /catalog/list` and `POST /inventory/counts/batch-retrieve`
(a read). Both checks run before every request, and the integration test fails if
the mock ever sees another call or a mutation body. Real-store use still needs the
owner to supply credentials and say go; no live credentials were used.

- **Connections:** owners (signed in, not tokens) store Shopify
  (`shop_domain`, `client_id`, `client_secret`) or Square (`access_token`,
  `environment`) credentials. They are sealed with AES-256-GCM, key derived per
  tenant from `RUPERT_MASTER_KEY` (base64, 32 bytes) via HKDF, and bound to
  tenant and provider as associated data. Responses never include secrets; the
  test also greps the data directory for plaintext. Shop domains must match
  `*.myshopify.com` (no arbitrary URLs, so no SSRF). Upstream base URLs can be
  overridden only when `RUPERT_DEV=1`.
- **Sync:** `POST /api/v1/sync/{shopify|square}` (manager+, scope `sync:run`) returns
  202 and runs in the background; one run per tenant+source (409 otherwise),
  process-wide concurrency `RUPERT_SYNC_CONCURRENCY` (default 2). Pages are
  streamed and committed per page, so memory does not grow with catalog size.
  Cursor pagination is followed to the end, including Shopify variants beyond 100
  per product. Bounded retry covers 429/503 (Retry-After, max 10 s) and stale
  pooled connections. History: `GET /api/v1/sync/runs`.
- **Safety:** a run that returns zero variants never deletes a populated mirror
  (fails with "refusing ..."). Stale rows are removed only after a fully
  successful pass.
- **Mirror reads:** `GET /api/v1/catalog` and `/api/v1/inventory` follow the
  paging contract in `docs/api-v1.md` (`page` 1-1000, `per_page` 1-100, `meta`
  with `has_more`/`next_page`). Square quantity is the sum of IN_STOCK counts over
  ACTIVE locations. Per-location Shopify levels and orders are not mirrored yet.
- **Realtime:** every mirror change, sync result and POS-side adjust appends to the
  tenant's `events` outbox in the same transaction, then is broadcast.
  `GET /api/v1/events` is SSE with `id:` per event; reconnect with `Last-Event-ID`
  (or `?since=`) and the server replays missed events from the outbox before
  following live ones, so drops and slow consumers lose nothing. Unchanged re-syncs
  emit only `sync.finished`. `GET /api/v1/events/recent` is the polling form.
  Streams close after 10 minutes (clients reconnect), which bounds how long a
  revoked token can keep a stream. Limits: 50 streams per tenant, 1000 total
  (`RUPERT_SSE_MAX`). The outbox is pruned to the latest 10,000 rows per sync.

Bug found by the mock and fixed: a pooled keep-alive connection closed by the
server made the next POST fail with "Peer disconnected" (3 failures in 8 runs);
real upstreams close idle connections too. Reads are safe to retry, so the client
now retries network errors up to 3 times.

Measurements (same harness as above, medians of 5 runs of 6 s, 32 connections,
loopback, shared laptop):

| Run | RSS after 500 tenants | Read rps / p99 | Write rps / p99 |
| --- | --- | --- | --- |
| milestone 2 (auth) | 40 MB | 99-101k / 1.95 ms | 75-82k / 2.1-2.2 ms |
| milestone 3, run 1 | 42 MB | 88.7k / 2.70 ms | 50.8k / 3.32 ms |
| milestone 3, run 2 | 43 MB | 87.0k / 2.64 ms | 33.2k / 3.96 ms |

(Superseded by the A/B below: the milestone-2 read figure of ~100k came from a quieter
machine. Re-run back to back today, both builds read at 85-89k.)

**SSE memory (resolved, see follow-up below).** The first cut used ~90-120 KB per stream.

### Follow-up: SSE memory and the milestone 2 vs 3 A/B (2026-10-16)

Method: 1000 simultaneous SSE streams (20 per tenant over 50 tenants, the per-tenant
cap is 50), RSS read from `/proc` at 2 s and 16 s, server started fresh each run;
read/write numbers as before (medians of 5 x 6 s, 32 connections).

What was measured, in order:

| Experiment | RSS for 1000 streams |
| --- | --- |
| before (task per stream, DB read per stream start, unbounded blocking pool) | 99-127 MB |
| bare SSE response, no task/DB/auth (floor: hyper + axum Sse) | 35 MB (~29 KB per stream) |
| 1000 plain keep-alive connections after one request | 33 MB (~27 KB each) |
| per-tenant footprint (same 1000 streams on 20 vs 50 vs 100 tenants) | ~1 MB per active tenant while each stream opened reader connections |
| **after** (below) | **56-64 MB, median 58 MB** over 5 runs |

Findings and changes:
- The future per stream is only 560 bytes, so the task was not the cost.
- The real costs were reader SQLite connections: every stream start did a DB read
  (cursor lookup, then an initial replay) and so opened up to 8 reader connections
  per tenant. Fix: each tenant keeps an atomic `last_event` cursor (advanced on
  publish), and a client that is already current skips the initial replay. Both
  replay paths stay covered by `tests/sync_smoke.py` (live delivery and
  `Last-Event-ID` replay).
- The blocking pool defaulted to 512 threads and a burst of 1000 stream starts used
  471; it is now capped (`RUPERT_BLOCKING_THREADS`, default 64; 75 threads peak).
  On its own this saved only ~5 MB, so it was a minor factor.
- A shared per-tenant fan-out task was not needed: after the fixes a stream is
  ~29 KB of HTTP/SSE floor plus ~20 KB of our state. Fan-out still delivered to
  20 of 20 listeners of a tenant in every run.
- Remaining per-tenant cost (~0.3-0.5 MB per active tenant: writer connection, shm,
  broadcast buffer) is bounded by `RUPERT_MAX_OPEN` (default 64).

A/B of the milestone 2 commit against current, built and run back to back on the
same machine (2 rounds each, medians of 5 runs per round):

| Build | Read rps / p99 | Write rps / p99 | RSS after 500 tenants |
| --- | --- | --- | --- |
| milestone 2 (e850cd2) | 85.0k, 87.7k / 2.7 ms | 113.5k, 113.4k / 1.0 ms | 40-43 MB |
| milestone 3 + memory fixes | 86.4k, 88.7k / 2.6-2.7 ms | 74.4k, 75.1k / 1.2 ms | 42-43 MB |

Reads are unchanged. Writes are ~35% lower: each adjust now also inserts an `events`
row and serialises its JSON inside the same transaction, which is the price of the
replayable realtime feed.

### Follow-up: trying to win the write cost back (2026-10-16)

Tried, in order, each A/B'd interleaved against milestone 2 on the same machine
(medians of 5 x 6 s per cell, write rps; **compare within a session only**, the
absolute level of the same binary drifted between 52k and 113k across sessions):

| Variant | Write rps (per round) |
| --- | --- |
| milestone 2 (no outbox) | 52.5k, 56.5k / 55.6k, 58.9k / 81.8k, 66.9k, 65.1k |
| milestone 3, per-row event insert (AUTOINCREMENT) | 33.1k, 32.9k / 33.1k, 33.5k / 37.7k, 36.7k, 40.5k |
| A: one multi-row `INSERT ... RETURNING` for events per group commit | 27.9k, 28.2k |
| B: A + `UPDATE ... RETURNING` + multi-row movements insert | 21.6k, 23.1k / 23.3k, 22.3k |
| C: constant SQL via `json_each` (events and movements) | 20.1k, 19.9k |
| **D: per-row insert, no AUTOINCREMENT (shipped as migration 3)** | **39.0k, 42.5k, 43.9k** |

- **Batching the event rows made writes slower, not faster** (about 15-40% below the
  per-row version in every round). My hypothesis that varying-length SQL defeated the
  statement cache was wrong: the constant-SQL `json_each` form was slower still. I did
  not profile further, so the real reason (JSON build/parse per batch is the likely
  cost) is unconfirmed. All batching code was reverted.
- **Dropping `AUTOINCREMENT` helps:** 3 of 3 rounds, median 37.7k -> 42.5k (~+12%). The
  outbox never reuses ids because pruning keeps the newest rows, so the per-insert
  `sqlite_sequence` write was pure overhead. Migration 3 rebuilds the table in place;
  verified against a data directory created by the old schema (version 2 -> 3, existing
  events kept, 20,000 concurrent adjusts still exactly accounted for).
- Net: writes remain ~36% below the no-outbox baseline (median 42.5k vs 66.9k in the last
  session). Reads are unchanged in every comparison.
- New test `tests/adjust_consistency.py`: 20,000 concurrent adjusts on one SKU must
  produce exactly that many quantity drops, `movements` rows and `events` rows, with
  unique event ids. It passes for every variant above, so the batching variants were
  slower but not incorrect.
- A first A/B round was run while a previous benchmark was still going and collided with
  it (leftover server on the port); that round was discarded and re-run clean.
- Untried ideas: make the outbox optional per tenant (the cost is paid even with no
  subscribers), write events from a separate connection after commit (weaker durability),
  or store compact non-JSON payloads.

Not done: Shopify per-location levels and orders, Square orders, scheduled
(automatic) syncs, webhooks, mirror search, SKU linking between Shopify and Square,
and no real-store run (needs owner credentials and approval).

### Per-tenant realtime switch (2026-10-16)

The `events` outbox is now optional per tenant. Stored in the tenant's own database
(`settings` table, migration 4), cached in an atomic on the open tenant, default on
(`RUPERT_REALTIME_DEFAULT=0|1` sets the default for tenants with no stored setting; a stored
setting always wins and survives restarts).

- `GET /api/v1/settings` (staff+) returns `{"realtime": bool}`.
- `PUT /api/v1/settings {"realtime": bool}` is owner-only and session-only (tokens get 403).
- **Off:** no `events` rows are written (inventory adjusts, mirror sync, sync results), nothing is
  broadcast, `GET /api/v1/events` and `/events/recent` return 409. Adjusts, `movements` rows, syncs
  and the mirror reads are unaffected; sync status stays available at `/api/v1/sync/runs`.
- **Turning it on** writes one `realtime.enabled` marker. Changes made while it was off are not in
  the outbox, so clients that see the marker (or got a 409 earlier) must resync from
  `/api/v1/catalog` and `/api/v1/inventory` instead of replaying. Streams already open when it is
  switched off stay connected but receive nothing until it is on again.
- Tests: `tests/sync_smoke.py` is now 56 checks (owner-only toggle, adjust and sync still work
  while off, zero event rows written, 409 on both feed endpoints, marker on enable); a manual
  check confirmed 5000 concurrent adjusts with realtime off give 5000 movement rows, 0 events and
  the exact quantity drop, and that a stored `0` beats `RUPERT_REALTIME_DEFAULT=1` after restart.

A/B against milestone 2, interleaved on the same machine, 3 rounds, medians of 5 x 6 s per cell
(then median of the three rounds), fresh data copy per run:

| Build | Read rps / p99 | Write rps / p99 | RSS after 500 tenants | Peak RSS |
| --- | --- | --- | --- | --- |
| milestone 2 (no outbox) | 90.7k / 2.59 ms | 56.7k / 2.36 ms | 47 MB | 67 MB |
| current, realtime ON | 88.6k / 2.62 ms | 42.2k / 2.98 ms | 44 MB | 65 MB |
| current, realtime OFF | 86.9k / 2.72 ms | 57.1k / 2.37 ms | 44 MB | 63 MB |

Per-round writes: M2 59.7k, 56.7k, 56.7k; ON 40.6k, 42.6k, 42.2k; OFF 54.8k, 61.8k, 57.1k.

- Realtime OFF restores milestone-2 write performance (57.1k vs 56.7k, inside round-to-round
  noise). Realtime ON costs about 26% of writes (42.2k vs 56.7k) and ~0.6 ms of write p99.
- Reads are within noise of each other (one OFF round measured 77k; the other two 87k and 90k),
  so no read difference is claimed.
- Absolute numbers differ from the previous session's table (this machine drifts between
  sessions); only the within-session ordering is meaningful.

## First live run: read-only sync of the production store (2026-10-16)

Tenant #1 is the production shop (`m11u0i-sb.myshopify.com`, Square production, 3 locations), loaded
into a local-only Rust Rupert (`scripts/run-live.sh`, `scripts/live-load.py`) using the credentials the
Rails app already uses, copied over SSH from the `rupert` container's `/etc/rupert.env` into a private
file (`~/.config/rupert-core/live.env`, mode 600). Nothing was written to Shopify, Square or the
server. Data stays local (`core/data-live`, gitignored).

Read-only evidence:
- `RUPERT_LOG_UPSTREAM=1` ledger (method, path, GraphQL operation, status; no bodies or secrets). Across
  three full sync passes the only calls were: `POST /admin/oauth/access_token` (token exchange),
  `POST .../graphql.json` with operation `Products` (a query), `GET /v2/locations`,
  `GET /v2/catalog/list` and `POST /v2/inventory/counts/batch-retrieve` (a read). All HTTP 200; zero
  writes, no `mutation`.
- Secret scan of the local data directory, server log and loader output found no credential.
- A repeat sync changes nothing (0 added, 0 changed, 0 removed).
- Server-side access used read-only commands only: env key names, `sqlite3 -readonly` on the Rails
  production database, and the Tailscale-SSH approval the owner granted in the browser.

Parity against the live Rails mirror (read from `production.sqlite3`; counts compared per row):

| | Rails | Rust | Differences |
| --- | --- | --- | --- |
| Shopify variants (rows refreshed today) | 351 | 351 | 0 missing, 0 extra, 0 SKU, 0 quantity (sum 3,283 = 3,283), 0 status |
| Square variations | 741 | 741 | 0 missing, 0 extra, 0 SKU, 0 quantity (sum 2,385 = 2,385) |

The first run was **not** at parity and the report found two causes, both fixed (migration 5 plus
sync changes, covered by `tests/sync_smoke.py`, now 59 checks):
1. **Product status.** The shop has 90 products: 42 active, 8 draft, 40 archived. The Rails source on
   `main` queries `status:active` only, but the production mirror holds and refreshes all statuses
   (ACTIVE/DRAFT/ARCHIVED), so production is not running what `main` says. Rust now fetches every
   status and stores `product_status` (exposed as `status` in `/api/v1/catalog`). This is a code/deploy
   discrepancy worth checking on the Rails side.
2. **Oversold stock.** Rails mirrors negative Shopify stock as 0 and counts oversold tracked variants;
   Rust had stored the raw negatives (50 rows differed). Rust now clamps to 0 and reports `oversold`
   in the run details (0 tracked variants were oversold on this run).

Also observed on the Rails side, not changed: its `ShopifyVariant` table holds 902 rows, 551 of which
were last refreshed in August and are never removed, so raw Rails counts overstate the live catalog.
The Rust sync removes variants that disappear from Shopify after a successful run.

Not covered by this run: orders, per-location Shopify levels, scheduled syncs, webhooks.
