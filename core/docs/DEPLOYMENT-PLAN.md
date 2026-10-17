# Plan: public deployment of Rust Rupert on SER8

Status: **plan only, nothing executed.** Written 2026-10-16 after a read-only survey of SER8 (commands listed in
section 1). Rails Rupert, its Postgres container, Caddy and every other project on the host stay untouched until the
owner approves a phase.

## 0. Shape of the plan in one paragraph

Run the Rust app as a **new, separate Incus container (`rupert-core`)** on its own hostname, next to the Rails app.
Rails keeps serving everything it serves today. The Rust app starts as a read-only, shadow copy of the store
(catalog, inventory, per-location levels, orders, realtime feed, webhooks) that is compared against Rails every day.
Routes move from Rails to Rust one at a time in Caddy only when parity is shown, and each move can be undone by
deleting one `handle` block. This is a strangler, not a cutover: the Rust app covers roughly 14 tables of Rails' ~93
and none of its POS checkout, timesheets, bulk materials, payroll or reporting, so "migrating from Rails" today means
standing up the read side, not moving data.

## 1. What the survey found (read-only, 2026-10-16/17)

| Fact | Detail | Consequence |
| --- | --- | --- |
| Host | SER8, x86_64, 16 cores, 26 GB RAM (about 20 GB available), 915 GB disk with 467 GB free | plenty of room |
| Our dev machine | **aarch64** (Asahi), glibc 2.43 | the binary tested so far **cannot run on SER8**; build natively on x86_64 |
| Rails container | `rupert`, Ubuntu 24.04 (glibc 2.39), limits 2 CPU / 4 GiB / 16 GiB disk, using 1.6 GiB RAM; Postgres in `rupert-db`; Puma on :3000 and a stage unit on :3001 | Rust needs ~35-60 MB, a tiny container is enough |
| Other tenants on the host | daedalus-prod, scanner, energy-monitor, haven, homeboard, pin-telemetry, sonder, swartzit | shared host: do not touch their config |
| Caddy 2.6.2 | `admin off`, one shared `/etc/caddy/Caddyfile`, root-owned, `sudo` needs interactive approval; sites bind `192.168.3.251` (the WireGuard-facing address); logging snippet `cockpit_incus_access`; certificates by TLS-ALPN (port 80 not reachable) | a route change needs `sudo` and a Caddy **restart** (no live reload with the admin API off): a brief blip for every site |
| Public names pointing at Rails | `rupert.stoverparc.org`, `rupert.cybersecuritypilot.org`, `herbalhealers.cybersecuritypilot.org`, `pos.rupertpos.com` -> `10.96.131.8:3000` | new hostname for Rust; do not reuse these yet |
| Existing backups | in-container `rupert-backup.timer` every 6 h (VACUUM INTO + settings dump + env copy, keeps 32), 8.5 GB retained; frequent Incus snapshots; host `incus-backup.timer` weekly; `rupert-sync-watch` host timer (fails if newest sync is older than 45 min) | reuse these patterns |
| Known operational trap | Rails docs: host AppArmor/signal issue breaks ordinary service/container restarts; do not disable AppArmor or make a container privileged | prove restart behaviour in the new container **before** relying on it |
| My access | Tailscale SSH (needs the owner's browser approval per session), member of `incus-admin` (can create containers), **no sudo** | I can build and run the container; the owner must do the Caddy/DNS steps |
| Off-host recovery | Rails docs list it as unverified | same gap applies; fix once for both |

## 2. Target architecture

```
Internet --(WireGuard/public)--> Caddy 192.168.3.251:443  [shared, root-owned, admin off]
                                   |-- rupert.*  ------------------> rupert  10.96.131.8:3000   (Rails, unchanged)
                                   |-- core.<domain> (new site) ---> rupert-core 10.96.131.X:8798 (Rust, new)
                                   `-- other projects (untouched)
rupert-core: Ubuntu 24.04, unprivileged, 1 CPU / 512 MiB / 8 GiB
  /usr/local/bin/rupert-core        single binary, built on x86_64, SHA-256 recorded
  /etc/rupert-core/env               0600: RUPERT_MASTER_KEY, RUPERT_PUBLIC_URL, limits (see section 5)
  /var/lib/rupert-core/              central.db + tenants/<id>.db (WAL)  <- the only state
  systemd unit with NoNewPrivileges, ProtectSystem=strict, PrivateTmp, MemoryMax=512M, Restart=on-failure
```
Hostname proposal (owner decision): `core.stoverparc.org` (same domain family as the other SER8 sites, same DNS path).

## 3. Code that must exist first (not built yet)

1. **Graceful shutdown** (SIGTERM: stop accepting, finish in-flight group commits, checkpoint the WAL). Today a stop
   kills in flight work; SQLite stays consistent but a clean stop is required for restarts and snapshots.
2. **x86_64 release build.** Preferred: build inside a throwaway Incus container on SER8 (Ubuntu 24.04, same glibc as
   the runtime, 16 cores), record `git rev` and SHA-256 of the binary. Alternative: musl static cross-build from here
   (bundled SQLite and `ring` need a musl C toolchain; try only if the native build is inconvenient).
3. **Health/monitoring endpoint** (authenticated): last sync age per provider, schedule state, request budget used,
   DB sizes. A host timer like `rupert-sync-watch` alerts when a sync is overdue.
4. **Structured logs to stdout** (journald), no secrets, no URLs containing webhook tokens or order ids.
5. Before inviting anyone other than the owner: **TOTP MFA, password reset, email delivery for invites**, and the
   Rails bcrypt import if existing users should keep their passwords. For a single-owner pilot behind a long random
   password this can wait, but multi-tenant hosting must not go public without MFA.
6. An admin UI is not required for the pilot (everything is API plus `scripts/`), but it is the next usability gap.

## 4. Phases (each has a check and an undo; I would do 1-4 only after approval, 5+ need the owner)

| # | Phase | Changes | Check | Undo |
| --- | --- | --- | --- | --- |
| 0 | Decisions (section 8) | none | answers recorded | n/a |
| 1 | Code prerequisites 3.1-3.4 | repo only | tests green, SIGTERM test, `cargo test` | revert commit |
| 2 | Build on SER8 | one throwaway build container | binary runs `--help`-level smoke on x86_64, hash recorded | delete build container |
| 3 | Create `rupert-core` container (new, unprivileged, limits above), install binary and unit | new container only | `systemctl restart` and `incus restart rupert-core` both work **inside the new container** (the AppArmor trap), `/healthz` answers from the bridge | `incus delete rupert-core` |
| 4 | Secrets and tenant bootstrap | `/etc/rupert-core/env` (generated master key, 0600); tenant `herbalhealers` created; Shopify/Square credentials copied by the same read-only method as the local run (never printed) and sealed under the new master key | local `curl` from the host: signup/login, connections stored, first read-only sync, **ledger shows reads only** | wipe `/var/lib/rupert-core`, delete env |
| 5 | **Caddy + DNS (owner, needs sudo)** | add one site block for `core.<domain>` (with `import cockpit_incus_access`, `bind 192.168.3.251`, `encode zstd gzip`, `reverse_proxy 10.96.131.X:8798`, `request_body max_size 1MB` for `/hooks/*`); `caddy validate`, keep a `Caddyfile.pre-rupert-core-DATE` backup, **restart in a quiet window** | `curl https://core.<domain>/healthz`; certificate issued; other sites still answer (checklist of every hostname) | restore the backup file and restart Caddy |
| 6 | Shadow period (2 weeks) | schedules on (15 min), orders on | daily parity report vs Rails (script from the live run): Shopify variants/levels/orders and Square variations/counts/orders; request meter well under budget; no run over 30 s | turn schedules off |
| 7 | Backups and a restore drill | timer + off-host copy | restore a backup into a scratch container, run parity again | n/a |
| 8 | Webhooks (**owner approves the writes**) | owner adds the URLs in Shopify admin and Square Developer dashboard (or approves one-off registration); stores Square signature key and exact URL | signed test events from the providers show `accepted`; `GET /api/v1/webhooks` outcomes; scheduled sync stays as the safety net | delete subscriptions in the dashboards, `DELETE /api/v1/webhooks/token` |
| 9 | Route cutover, one route at a time | Caddy `handle` blocks, e.g. `/api/v1/catalog*`, `/api/v1/inventory*` -> Rust, everything else -> Rails | parity report for that route for 1 week, error rate and p99 from Caddy logs | delete the `handle` block, restart Caddy |
| 10 | Hardening and operations | MFA, log shipping, alerting, access review | checklist in section 7 | n/a |

Rails-side authentication differs (Rails users/sessions vs Rust tokens), so route moves in phase 9 start with API
routes that use bearer tokens (`/api/v1/*`), not browser pages.

## 5. Configuration (env file, all optional unless marked)

`RUPERT_MASTER_KEY` (required, base64 32 bytes, generated once), `RUPERT_PUBLIC_URL` (required for webhook URLs),
`RUPERT_TRUST_PROXY=1` (required behind Caddy so rate limits see the real client IP), `RUPERT_BASE_DOMAIN`,
`RUPERT_LISTEN=0.0.0.0:8798` (only the bridge; Caddy is the sole client), `RUPERT_API_BUDGET_PER_HOUR=1000`,
`RUPERT_MAX_REQUESTS_PER_RUN=5000`, `RUPERT_MAX_OPEN=64`, `RUPERT_SSE_MAX=1000`, `RUPERT_ORDER_LOOKBACK_DAYS=30`.
Never set `RUPERT_DEV` in production (it enables test upstream overrides and the dev seed endpoint).

## 6. Backups and recovery

- State is `central.db` plus one SQLite file per tenant. A backup is a consistent `VACUUM INTO` (or `.backup`) of each
  file taken by a timer every 6 h, integrity-checked, gzipped, 0600, pruned to 32 (same pattern as `bin/backup.sh`).
- **Incus snapshot before every deploy** (`rupert-core@pre-<git-rev>`), kept for a week.
- **The master key is escrowed separately** (owner's password manager), not inside the backup bundle: losing it makes
  stored provider credentials unreadable (they can be re-entered), leaking it together with a backup exposes them.
- Because mirrors are re-derivable from Shopify/Square, the irreplaceable data is small: users, memberships, tokens,
  schedules, settings, audit log. Recovery time objective for a total loss is "restore central.db, re-run syncs".
- Off-host copy (to the same destination chosen for Rails) and a **quarterly restore drill** into a scratch
  container, verified with the parity script. Until the drill passes, do not rely on the backups.

## 7. Security checklist before the hostname is public

- Only Caddy can reach :8798 (container firewall or bind to the bridge only); no direct public listener.
- TLS by Caddy; HSTS added at the site block; `RUPERT_COOKIE_SECURE` left on.
- `/hooks/*`: body cap 1 MiB (also enforced in the app), per-token and per-IP rate limits in the app, and Caddy
  `rate_limit` is not available in stock Caddy, so rely on the app limits plus provider HMAC verification.
- Secret hygiene: env file 0600 root-owned, no secrets in unit files, logs, ledger or API responses (covered by tests).
- Admin actions are owner-only and session-only (tokens cannot rotate webhook tokens, change connections or
  settings). Known gaps to close before multi-customer use: MFA, password reset, per-account lockout beyond the
  per-process rate limits, single central DB as a single point of failure (backups cover it).
- Systemd sandboxing as in section 2; unprivileged container; AppArmor left enabled.

## 8. Decisions needed from the owner

1. Hostname and DNS (`core.stoverparc.org`?) and who edits Caddy (needs `sudo`; or grant a narrow sudo rule for
   `systemctl restart caddy` plus write access to one included file so future changes avoid editing the shared Caddyfile).
2. Approval to create the `rupert-core` container and a throwaway build container on SER8 (phases 2-4, no public exposure).
3. Approval for webhook registration (a write to Shopify/Square) when phase 8 is reached, or the owner does it in the dashboards.
4. Where off-host backups go and who holds the master key escrow.
5. Whether the shadow period uses the production store only, or also the Square sandbox first.
6. Acceptable maintenance window for the Caddy restart (it briefly interrupts every site on the host).

## 9. Risks

| Risk | Mitigation |
| --- | --- |
| Shared Caddy restart interrupts other projects | validate first, backup file, quiet window, checklist of every hostname afterwards; ask for an include-file arrangement to avoid touching the main file again |
| Container restart problem (AppArmor/signal issue seen on Rails) | test in the new container in phase 3; use the documented service-cgroup procedure if it reproduces; never disable AppArmor |
| Rust app mistaken for a full Rails replacement | scope table in section 0; route-by-route cutover with parity evidence |
| Provider throttling or runaway loops | request meter, per-run cap, hourly budget (all built and tested); scheduler minimum 5 minutes |
| Single hot process (no HA) | acceptable for a pilot; fast restore from snapshots/backups; Rails stays authoritative |
| Wrong binary architecture or libc | native x86_64 build in an Ubuntu 24.04 container; hash recorded; smoke test in phase 3 |
| Secrets exposure when copying credentials | same private-file method as the local run; never printed; sealed immediately; the scratch file removed |
| Parity drifts silently | daily parity report, alert on any difference not explained by timing |

## 10. Done means

Phases 1-7 complete, two clean weeks of daily parity with zero unexplained differences, a restore drill passed from
an off-host copy, webhook events observed end to end, and the owner has chosen which routes (if any) move to Rust.

## 11. Execution log: phases 1-4 (2026-10-17, approved by the owner; no Caddy, DNS or webhook changes)

**Phase 1 (code, done).** Graceful shutdown, `/api/v1/health`, JSON logs by route template; commit `5299b7e`, rebased on
the owner's rustfmt/clippy/CI commit (#96) and compliant with it (`cargo fmt --check`, `clippy -D warnings`).
Tests: 5 unit, 41 auth, 130 sync/orders/webhooks, 15 ops (SIGTERM with an open stream folds the WAL to zero, overdue
detection, no secret URL or token in logs).

**Phase 2 (build, done).** Throwaway Ubuntu 24.04 container on SER8; rustup installer verified against its published
SHA-256; rustc 1.99.1; `cargo build --release --locked` in 72 s. Artifact `~/rupert-core-releases/5299b7e/rupert-core`
(x86_64, 6.4 MB, links only libc/libm/libgcc_s), SHA-256 `667ea41b45acfb6136caa14562c60a16150550632e3f367c9472fc31be0f44de`,
with `BUILD-INFO`, `SHA256SUMS` and the test sources. All suites pass **on this x86_64 binary** (run on the host,
because of the signal problem below). The build container was deleted afterwards.

**Phase 3 (container, done) and a finding that needs a decision.** `rupert-core`: unprivileged, 1 CPU, 512 MiB, 8 GiB,
`10.96.131.175:8798`, systemd unit (`rupertcore` user, `ProtectSystem=strict`, `NoNewPrivileges`, `MemoryMax=480M`,
start limit 5 per 5 min so a failed restart cannot loop forever), env file 0600 with a generated master key.
Restart test, as the plan required: **`systemctl restart` inside the container fails** (the old process cannot be
killed: "Found left-over process ... Ignoring", the new one dies with "Address already in use"). The documented
host-side recovery works: `incus restart rupert-core --force` brings up exactly one healthy process.

*Root cause (measured, kernel log).* Host kernel 7.0.0-38 with AppArmor 5.0.2 denies `signal` between **all** processes
in the container, including systemd and `kill -0` on its own child: the sender is the container profile
(`incus-<name>_</var/lib/incus>`) and the target's label is the stacked `incus-<name>_</var/lib/incus>//&unconfined`,
which the stock rule (`peer=@{profile_name}`) does not match. This is not limited to "processes from an older
profile" as the Rails notes suspected; it affects fresh containers (reproduced on the build container within
minutes of creating it). Consequences for any service in any container on this host: no in-container stop or
restart, and no graceful SIGTERM at host `incus stop` either (systemd's SIGTERM is denied, the host then kills),
so Phase 1's checkpoint-on-stop only helps when the process is stopped some other way. SQLite recovers from a
hard kill, so data is safe; only the clean shutdown is lost.

*Options for the owner.*
- **A (recommended, needs approval): a narrow per-container AppArmor rule** (`raw.apparmor` allowing signals to
  the container's own stacked label), tried first on a throwaway container to find the minimal rule, then applied to
  `rupert-core` only. This does not disable AppArmor, make the container privileged or touch other containers. It is a
  security-policy change, so it was not applied without approval. The same fix would likely repair `rupert`.
- **B: accept the limitation.** Deploy and restart only with `incus restart rupert-core --force` (a short outage each
  time, no graceful shutdown).
- **C: run the service on the host** instead of in a container (no container confinement, weaker isolation).

**Phase 4 (bootstrap, done).** Tenant `herbalhealers` created (owner login `owner@rupert-core.local`; the random password
is in `/root/.config/rupert-core/live-owner.json` inside the container, mode 600; change the email/password before any
real use). The five Shopify/Square variables were copied container-to-container on the host without being printed,
sealed under the new master key, and the plaintext copy was shredded. First read-only sync from the new container:
Shopify 351 variants, 354 per-location levels, 208 orders in 9 s; Square 741 variations, 121 orders in 3 s.
- Upstream ledger (journal): only the allowlisted reads, all HTTP 200, zero write-like calls, zero throttles
  (Shopify 36 requests, Square 13).
- Credential scan of the data directory and journal: nothing found.
- `scripts/parity.py` (read-only, runs on SER8) against the live Rails database: **no differences** across Shopify
  variants (351), per-location levels (200 fresh Rails rows), locations, Square variations (741) and non-zero counts
  (238), Shopify orders (191) and Square orders (121). One orphan Rails count row (1 unit, a variation that no longer
  exists) is reported as information.
- Footprint: service RSS 36 MB, container memory 59 MiB of 512, data 3.6 MB.
- Baseline Incus snapshot `phase4-baseline-5299b7e` taken as a rollback point.

**State left on SER8:** new container `rupert-core` (running, autostart); `~/rupert-core-releases/5299b7e/`. Nothing else
was changed: Rails, Caddy, DNS and every other container are as they were (Rails `/up` answers 200). Scheduled syncs
are off, `RUPERT_PUBLIC_URL` is a placeholder, no backup timer yet (phase 7), the master key exists only in the
container's env file and its snapshot (escrow decision still open), and no webhooks are registered.

**Next (needs the owner):** choose A/B/C for the signal problem; then phase 5 (hostname, DNS, Caddy with `sudo`) and the
shadow period.

## 12. The container signal problem: option A applied and verified (2026-10-17, owner approved)

**Rule.** One line in the container's own AppArmor raw rules, applied to `rupert-core` only:

```
incus config set rupert-core raw.apparmor='signal (send,receive) peer=@{profile_name}//&unconfined,'
```
It lets processes in the container signal each other (their label is this profile stacked with `unconfined`) and nothing
else: the peer must be this container's own label, so it grants nothing toward the host or other containers (which also
sit in separate PID namespaces). It does not disable AppArmor, make the container privileged or change any shared
policy. Precedent on this host: the `sonder` container already carries an equivalent, slightly broader rule
(`peer="incus-sonder_</var/lib/incus>//&*"`). No other container was changed (checked: `rupert`, `rupert-db`,
`homeboard`, `daedalus-prod` have none).

**Proof, on a throwaway container running the same binary and unit (`scripts/signal-test.sh`):**

| Check | Without the rule | With the rule |
| --- | --- | --- |
| a process signals its own child | denied | works |
| `systemctl restart rupert-core` | stranded old process, new one panics "Address already in use" | clean replacement, 1 process, healthz ok |
| graceful stop line (`shutdown requested` / `stopped`) on restart | none | present |
| kernel signal denials during the run | 9-11 | **0** |
| rule edited while the service runs (in-place profile reload, the case the Rails notes feared) | n/a | restart still clean, 0 denials |
| host `incus stop` then `start` | no graceful stop logged | graceful stop logged in the persistent journal, healthy after start |

The same test then passed on `rupert-core` itself (restart PID 429 to 458, 0 denials, host stop and start healthy), the
SQLite WAL files were all 0 bytes afterwards, and `scripts/parity.py` still reported no differences. The throwaway
container was deleted. The journal on `rupert-core` is now persistent (`/var/log/journal`), so stop/start history
survives restarts.

**Operating notes.** `systemctl restart rupert-core` and `systemctl stop` now work inside the container, and a host
`incus restart rupert-core` stops the service gracefully. Keep the start-limit in the unit anyway. Do not start
long-lived processes with `incus exec` in this container: use systemd units. The Rails `rupert` container has no such
rule and still suffers the original problem; the same one-line rule would fix it, but that is the owner's call and was
not applied.
