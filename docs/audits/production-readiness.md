# Production readiness audit — 2026-10-20

Audited at `main` commit `03db8bb` (2026-10-19). Fixes are on branch `claude/production-readiness` (small commits, each with tests).
Production at audit time ran build `4e45c061` (2026-10-19 12:09 EDT), 79 commits behind `main`; nothing on the branch is live until promoted.

## How this audit was done

**Verified by running** (inside a `ruby:4.0` podman container against a fresh clone of `main`):

| Check | Result |
| --- | --- |
| `bin/rails test` (SQLite) on `main` | 1881 runs, 14676 assertions, 0 failures |
| `COVERAGE=1 bin/rails test` (SQLite) on the branch | 1936 runs, 14918 assertions, 0 failures; line coverage 89.4%, all 14 coverage floors met (`bin/check-coverage --report`) |
| `bin/rails test` (PostgreSQL 16, podman) on the branch | 1936 runs, 14894 assertions, 0 failures, 0 errors, 4 skips (SQLite-only tests) |
| `bundle exec rubocop -c rubocop.yml` on the branch | 904 files, no offenses |
| `bundler-audit check --update` | No vulnerabilities (advisory db 2026-10-17) |
| `brakeman --compare config/brakeman-baseline.json` on the branch | 0 new, 0 fixed, 0 obsolete (20 baselined, triaged in `docs/ops/security-scanning.md`) |
| `node --test web/test/javascript/*_test.mjs` | 8 pass |
| `bin/build-product-site --check`, `bin/check-doc-links`, `git diff-tree --check` | pass |
| `bin/rails runner 'CustomerRedactJob'` on `main` | `NameError: uninitialized constant CustomerRedactJob` (see P0-1) |
| `podman build` of `Dockerfile` on `main` | **failed** at asset precompile (see P1-17) |
| `podman build` + `bin/rails runner` in the image on the branch | builds; boots in production mode on SQLite: `[:booted, "production", "SQLite", <sha>]` |
| `web/bin/restore-drill` against a 172-table test database | `DRILL OK`: integrity, foreign keys and per-table counts identical after restore |
| `deploy/ser8/rupert-offhost-backup.sh` against an `incus` shim | encrypts, decrypt-verifies, `sha256sum -c` sidecars pass, prunes by set, refuses without the key |
| SQLite write contention (`test/system_contention`) | 4 writer threads on separate connections × 25 interleaved transactions: no `SQLITE_BUSY`, no lost rows |
| `gh api repos/techmore/rupert/dependabot/alerts` | 48 open; 44 from `legacy/` lockfiles, 2 `mobile/` (backported), 1 root `package-lock.json`, 1 duplicate |
| `gh api .../branches/main/protection` | 404 "Branch not protected" |
| `curl -D - https://rupert.stoverparc.org/up` | 200, HSTS 2y, CSP present, `x-rupert-build 4e45c061…`, HTTP→HTTPS 301 |
| `curl https://rupert.cybersecuritypilot.org/up` | DNS does not resolve (this is the `application_url` in `shopify.app.toml`) |

**Only read** (not executed): the SER8 systemd units on the host itself (no host access; the new web unit and watcher changes are untested on SER8), the Google Drive backup path (no credentials), the mobile app (no device/EAS). The restore drill ran against a test database, not the production file.

**Could not check**: anything that needs live Shopify/Square credentials (actual GraphQL cost behaviour, Square `orders/search` acceptance of the current filter/sort combination), the SER8 host state (timers, AppArmor, disk), Google OAuth consent, EAS signing.

## Operating-model context the auditor must know

Rupert's sync is a **read-only mirror**: Shopify and Square are the systems of record for stock, and Rupert never decrements stock on an order. Each sync writes *absolute* per-location quantities (`direction: 'set'`), so a replayed or duplicated sync cannot double-decrement anything. Outbound stock writes exist only in explicit operator flows (`InventoryWriter`, size-family derives, SKU remediation) and carry idempotency keys. "Idempotent, retry-safe" therefore holds by construction for the mirror; the real risks are **staleness** (15-minute polling, no inventory webhooks), **partial reads** (guarded by transactions and validation), and **money correctness** (refunds, rounding).

Per `docs/ops/day-to-day-readiness.md` the shop currently runs **Shopify + C-Trax (retail stock) + SwipeSimple**; Square is configured in code but *not connected* in production. Findings below still cover Square because the code path is live the moment a token is saved.

## Findings

Severity: **P0** blocks go-live · **P1** needed in the first 30 days · **P2** later. Status: ✅ fixed on branch · 🟡 partly fixed / mitigated · ⛔ open (needs owner) · 📝 documented only.

### P0

| # | Finding | Evidence | Status |
| --- | --- | --- | --- |
| P0-1 | **Two mandatory GDPR webhooks crash with `NameError` after HMAC passes.** `customers/data_request` and `customers/redact` controllers call `CustomerDataRequestJob` / `CustomerRedactJob`; the job files define `CustomersDataRequestJob` / `CustomersRedactJob`. Shopify receives HTTP 500, retries, and the app fails compliance review. No webhook endpoint had a single test. | `web/app/controllers/webhooks/customer_redact_controller.rb:10`, `customer_data_request_controller.rb:10`, `web/app/jobs/customers_redact_job.rb:3`; `bin/rails runner 'CustomerRedactJob'` → NameError | ✅ Controllers fixed; jobs now actually redact/record; HMAC + 401 + enqueue tests added (`test/integration/shopify_webhooks_test.rb`) |
| P0-2 | **GDPR jobs were no-ops.** `CustomersRedactJob` and `ShopRedactJob` opened a session and did nothing; `customers/redact` must remove customer PII. | `web/app/jobs/customers_redact_job.rb:11-12`, `shop_redact_job.rb:11-12` | ✅ Redact job nulls PII on `Core::Customer` rows for the shop's customer ids/emails; data-request job records an `ActivityLog` entry for the operator; shop-redact job removes the Shop session and logs. Tests added |
| P0-3 | **Shopify `application_url` points at a dead host.** `shopify.app.toml` `application_url = "https://rupert.cybersecuritypilot.org"` does not resolve; relative webhook URIs in the TOML resolve against it, so compliance webhooks and the install flow target a dead host. | `shopify.app.toml:5`; `curl rupert.cybersecuritypilot.org` → "Could not resolve host" | 🟡 TOML now points at `rupert.stoverparc.org` (the documented production host). **Owner must run `shopify app deploy`** so the Partner Dashboard picks it up; see Needs owner |
| P0-4 | **No tested restore runbook with RPO/RTO.** Backups are taken (6-hourly `bin/backup.sh`, 5-minute rolling snapshots), restores were rehearsed ad hoc in deployment receipts, but there is no single runbook and the in-app `POST /settings/restore` always refuses (correctly). | `web/app/services/backup_service.rb:31-35`; `docs/ops/*deployment*.md` (scattered rehearsal notes) | ✅ `docs/ops/backup-restore-runbook.md` states RPO (5 min local / 6 h off-host) and RTO; `web/bin/restore-drill` runs snapshot → gzip → restore → `integrity_check`/`foreign_key_check` → row-count compare and was executed locally (test database). **Run it against the production file before go-live** |
| P0-5 | **Off-host backup copy is unencrypted and hard-coded to one operator's home directory.** `deploy/ser8/rupert-offhost-backup.sh` writes plaintext DB + `.env` (which contains the encryption keys) to `/home/sdolbec/backups/rupert`. | `deploy/ser8/rupert-offhost-backup.sh:5,13-16` | ✅ Script encrypts with `openssl enc -aes-256-cbc -pbkdf2` using a key file outside the backup set, verifies each file by decrypting and comparing digests before keeping it, writes ciphertext and plaintext checksum sidecars, prunes by set, refuses without the key, and ships as a host user timer (`rupert-offhost-backup.{service,timer}`). Verified against an `incus` shim. Key provisioning is under Needs owner |

### P1

| # | Finding | Evidence | Status |
| --- | --- | --- | --- |
| P1-1 | **Refunds and cancellations on orders older than 48 h never reach Rupert.** Both order fetches filter on `created_at >= watermark − 48h`; a refund issued on day 5 updates `displayFinancialStatus`/`state` on the platform but Rupert never re-reads that order, so sales and refund reports overstate revenue. No `Core::Refund` rows are ever created from platform data. | `web/app/services/catalog_syncer.rb:313` (`created_at:>=`), `square_client.rb:109` (`created_at` filter), `canonical_order_importer.rb` (no refund import) | ✅ Shopify query now filters `updated_at:>=` (sort `UPDATED_AT`) and fetches `refunds { id createdAt totalRefundedSet }`; Square search filters/sorts on `updated_at` and reads order `refunds`. Both import idempotent `Core::Refund` rows keyed by platform refund id. Tests added |
| P1-2 | **Money parsed through binary floats.** `Money.cents_from_amount` and four call sites use `to_f * 100`. Works for 2-decimal strings by luck of `.round`, violates the no-float rule, and `ShopifyVariant.price` is a `float` column used for inventory value and warehouse checkout pricing. | `web/app/services/money.rb:15`, `orders_controller.rb:60`, `canonical_order_importer.rb:232`, `business_snapshot.rb:66`, `warehouse_cart_item.rb:24`; `db/schema_sqlite.rb:200` (`t.float "price"`) | ✅ All conversions go through `Money.cents_from_amount` which is now `BigDecimal`-based and rejects malformed input; refund form validates the amount. Tests added. Changing the `price` column type is P2-7 |
| P1-3 | **No rate limiting on anything except password login (DB-backed).** Webhooks, bearer API, settings env/backup endpoints, public warehouse portal and signup have no throttle. | `Gemfile` (no `rack-attack`); `bin/rails middleware` output | ✅ `rack-attack` added: login (per IP and per email), signup, Google OAuth, webhook, API (per token / per IP), employee login, settings env/backup/restore, `/w/*` and customer display, plus a global ceiling; `/up*` safelisted; JSON 429 with `Retry-After`; throttled requests logged. Counters live in `Rails.cache` (file store on SER8; fine for one host, see P2-15). Tests added; throttles are off in the test env except in `RateLimitingTest` |
| P1-4 | **Shopify offline access token stored in plaintext.** `shops.shopify_token` / `refresh_token` are plain `string` columns while every other credential is `encrypts`-ed. | `db/schema_sqlite.rb:1973-1976`; `grep encrypts app/models/shop.rb` → none | ✅ `encrypts :shopify_token, :refresh_token` with `support_unencrypted_data` so existing rows keep reading; re-encrypt task `ops:encrypt_shop_tokens`. Tests added |
| P1-5 | **No retry/backoff on Shopify or Square HTTP calls.** A single `THROTTLED`, 429, 5xx or read timeout fails the whole 15-minute sync; `SyncJob` only retries `PreparedStatementCacheExpired`. | `shopify_client.rb:51-68`, `square_client.rb:44-55`, `sync_job.rb:6` | ✅ Bounded retry with exponential backoff + jitter and `Retry-After` honoured for 429/5xx/timeouts/`THROTTLED` in both clients; `SyncJob` retries transient categories (network, timeout, rate_limit, vendor) with polynomial backoff and gives up on credential/config errors. Tests added |
| P1-6 | **Hard-coded real shop domain as a code default.** `ShopifyClient.shop_domain` falls back to `m11u0i-sb.myshopify.com`; `.env.example` ships the same value. A misconfigured tenant would silently sync the wrong store. | `shopify_client.rb:25`, `.env.example:6` | ✅ Fallback removed (raises `ShopifyClient::Error` with reason `:invalid` when unset); `.env.example` blanked |
| P1-7 | **`legacy/` (dead Node app) accounts for 44 of 48 open Dependabot alerts (2 critical) and old droplet systemd units sit beside the SER8 ones.** The SER8 *web* unit is not in the repo at all — only jobs/backup are. | Dependabot alert manifest paths; `deploy/rupert-web.service` (droplet paths `/root/rupert`, `postgresql.service`); no `deploy/rupert-web-ser8.service` | ✅ `legacy/`, `db_import_legacy.rake` and the droplet units removed (history keeps them); `deploy/rupert-web-ser8.service` added matching the jobs unit; README/docs/.gitignore/.dockerignore updated |
| P1-8 | **No readiness signal for the job worker, sync freshness or disk.** `/up` only checks `SELECT 1`; the host watcher covers sync age but nothing exposes worker heartbeat or disk space to an uptime monitor. | `web/app/health/health_check.rb`; `deploy/ser8/rupert-sync-watch.sh` | ✅ `GET /up/ready` returns 200/503 with `database`, `worker`, `last_sync`, `disk` status words (no details); `rupert-sync-watch.sh` now also fails on low disk. Tests added |
| P1-9 | **No error tracking.** Exceptions go to stdout/journald only. | `Gemfile`; `config/environments/production.rb` | ✅ `sentry-ruby`/`sentry-rails` added, enabled only when `SENTRY_DSN` is set, PII scrubbed, release tagged with the build SHA. DSN under Needs owner |
| P1-10 | **SQLite contention untested; pragmas incomplete.** WAL + 5 s busy timeout are set, but `foreign_keys`, `journal_size_limit`, `mmap_size`, `cache_size` are not, and nothing tests web-vs-job write contention. | `config/database.yml:8-11`; no contention test | ✅ Pragmas added via `pragmas:` in `database.yml` and asserted by a test; `test/system_contention/sqlite_write_contention_test.rb` drives one writer thread per pooled connection (4 with the default pool) through 25 interleaved transactions each and asserts no `SQLITE_BUSY` and no lost rows (SQLite only) |
| P1-11 | **CI has no coverage signal and no `git diff --check`; mobile tests only run in a separate workflow.** | `.github/workflows/ci.yml` | ✅ SimpleCov added (test env only) with a `bin/check-coverage` gate on the sync engine and money files; `git diff --check` step added; coverage artifact uploaded |
| P1-12 | **Shopify API version pinned in three places with no upgrade plan or drift check.** | `shopify.app.toml:28`, `shopify_client.rb:17`, `config/initializers/shopify_app.rb:9` | ✅ Single `ShopifyClient::API_VERSION`, initializer reads it, test asserts TOML agrees; upgrade procedure in the operator runbook |
| P1-13 | **No operator runbook, env-var reference, release process or go-live checklist in one place.** Dozens of dated deployment receipts exist, but daily checks / stuck sync / key rotation / onboarding are not written down. | `docs/ops/` listing | ✅ `docs/ops/operator-runbook.md`, `docs/ops/environment-reference.md`, `docs/ops/release-process.md`, `docs/ops/go-live-checklist.md` |
| P1-14 | **Webhook deliveries are not deduplicated.** Shopify retries on any non-2xx; the GDPR jobs are idempotent, but a replayed `app/uninstalled` would be processed again and nothing records delivery ids. | `web/app/controllers/webhooks/*.rb` | ✅ `WebhookDelivery` table keyed on `X-Shopify-Webhook-Id`; duplicates are acknowledged (204) and skipped; rows retained 30 days for replay/forensics |
| P1-15 | **Branch protection off; Dependabot security updates off.** Anyone with push can land to `main` without CI. | `gh api .../branches/main/protection` → 404; `security_and_analysis.dependabot_security_updates: disabled` | ⛔ Needs owner (commands provided below) |
| P1-16 | **Production lags `main` by 79 commits** and deploys are manual `git pull` + restart on SER8 with no versioned release. | `x-rupert-build` header vs `git log`; `docs/BRANCHING.md` | 🟡 `docs/ops/release-process.md` (tag, promote, verify by build header, roll back) and `ExecReload` (Puma SIGUSR2) in the new web unit for near-zero-downtime reloads. The deploy itself remains a human action on SER8 (Needs owner) |
| P1-17 | **The production Docker image did not build, and would not have started.** Asset precompile ran with `RAILS_ENV=production`, where `database.yml` raised for a missing `POSTGRES_PASSWORD` and the encryption initializer for missing keys; `production.rb` crashed with `TypeError` from `Regexp.escape(nil)` whenever `HOST` was unset (also a real boot hazard on SER8); `entrypoint.sh` needs bash, which the Alpine base lacks. | `podman build` output; `config/environments/production.rb:96` | ✅ `SECRET_KEY_BASE_DUMMY` gates the build-time checks; `HOST` is now an explicit boot requirement with a clear message; bash and sqlite installed in the image. The image builds and boots in production mode on SQLite (verified) |

### P2

| # | Finding | Evidence | Status |
| --- | --- | --- | --- |
| P2-1 | No inventory/order **webhooks** from Shopify (`inventory_levels/update`, `orders/*`); freshness is bounded by the 15-minute poll. Acceptable for the current read-only mirror; needed before Rupert ever becomes the stock source of truth. | `shopify.app.toml` subscriptions | 📝 Design note in runbook |
| P2-2 | **Square token has no refresh path.** Square personal access tokens do not expire; OAuth tokens do. Code assumes a static token. | `square_client.rb:21` | 📝 |
| P2-3 | **CSP allows `unsafe-inline`** for scripts/styles. | `config/initializers/content_security_policy.rb` | 📝 Nonce migration tracked |
| P2-4 | `Access-Control-Allow-Origin: *` is applied to **every** response (template artifact). Cookies are never sent cross-origin with `*`, so impact is low. | `config/application.rb:38-42` | 📝 |
| P2-5 | **Shopify line items beyond 100 per order are not followed** (`lineItems(first: 100)` with no pagination; orders flagged `source_lines_complete=false`). | `catalog_syncer.rb:88` | 📝 |
| P2-6 | **Mobile app covers time/clock/timesheets only** (no barcode scan, count or adjust; no offline queue). Web `/employee` PWA and the scanner pages cover counts. | `mobile/App.tsx` | 📝 Owner decision |
| P2-7 | `ShopifyVariant.price` / `compareAtPrice` are **float columns**. | `db/schema_sqlite.rb:197,200` | 📝 Migration to `decimal(12,2)` recommended after P1-2 lands |
| P2-8 | **Google Drive backup consent blocked** (OAuth app in Testing); cloud copy has never succeeded. | `docs/ops/google-backup-verification.md` | ⛔ Needs owner |
| P2-9 | **Privacy policy / terms pages** absent (needed only if the app is listed or the warehouse portal is customer-facing). | `routes.rb` | 📝 |
| P2-10 | `strong_migrations`-style guard rails for migrations are absent; migrations have been rehearsed manually each release. | `Gemfile` | 📝 |
| P2-11 | **Audit log for stock adjustments** relies on `InventoryMovement` (mirror) and per-flow `ActivityLogger` calls; count approvals and reservations log, outbound `InventoryWriter` calls do not log the actor. | `grep ActivityLogger app/services/inventory_writer.rb` → none | 📝 |
| P2-12 | Root `package-lock.json` has 4 moderate npm advisories via `@shopify/cli`. | `npm audit` | 📝 bump when CLI releases |
| P2-13 | A single Puma process (no `workers`) and `JOB_THREADS=1`; fine for one shop, documented limits in `sqlite-incus.md`. | `config/puma.rb` | 📝 |
| P2-14 | **Both schema dumps are hand-maintained** and no longer match `db:schema:dump` output (table order, foreign-key placement, PostgreSQL 16's rendering of check constraints). Substantively equal today (checked by sorted-line diff), but the next regeneration will be a 1,000-line diff. | `git diff` after `db:migrate` on both adapters | 📝 Regenerate both in a dedicated commit after this branch merges; this branch inserts its one new table by hand to stay reviewable |
| P2-15 | Rack::Attack counters use `Rails.cache` (file store) on SER8: correct for one host, slightly slower than a memory/Redis store. | `config/initializers/rack_attack.rb` | 📝 Move to `solid_cache` or Redis if a second web process is ever added |
| P2-16 | `LocalEnvironmentTest` copies a hand-listed set of config files to boot in isolation; a new boot-time file silently breaks it (it did for `shopify_api_version.rb`). | `test/config/local_environment_test.rb:31` | 📝 List extended; consider copying `config/*.rb` |

## Docker image

On `main` the image did not build (P1-17). On the branch `podman build --from docker.io/library/ruby:4.0.6-alpine --build-arg RUPERT_BUILD_SHA=…` succeeds and `bin/rails runner` inside the image boots production on SQLite (`[:booted, "production", "SQLite", <sha>]`). The plain `ruby:4.0.6-alpine` short name needs a qualified registry on podman hosts; Docker resolves it. Compose still assumes PostgreSQL + Redis and remains an optional path; SER8 runs from the git checkout.

## What the branch contains

Sixteen-plus small commits: GDPR webhooks fixed and tested; webhook deduplication; Shopify config (API version pin, app URL, no default shop domain); Docker build and boot fixes; HOST boot check; Money on BigDecimal; legacy/droplet removal and the SER8 web unit; encrypted Shopify tokens; rack-attack; Sentry; client and job retries; `/up/ready`; SQLite pragmas and contention test; CI coverage floors/whitespace/pinned action; refunds import by `updated_at`; targeted tests for the ledger importer, Square client, inventory writer, token exchange and sync job; restore drill and encrypted off-host backups; the five runbooks and the CHANGELOG.

## Needs owner

1. **Run `shopify app deploy`** (from repo root, logged into the Partner account) after merging so the Partner Dashboard's `application_url` and webhook URIs move off the dead host. Confirm the app's redirect URLs no longer need `herbalhealers.cybersecuritypilot.org`.
2. **Set `SENTRY_DSN`** in `/etc/rupert.env` (or leave unset to keep error tracking off).
3. **Provision the off-host backup key**: `openssl rand -base64 48 > ~/.config/rupert/offhost.key && chmod 600 …` on the SER8 host, store a copy in the password manager, then enable the off-host timer. Without the key the script refuses to run.
4. **Enable branch protection and Dependabot security updates**:
   ```bash
   gh api -X PUT repos/techmore/rupert/branches/main/protection -F required_status_checks[strict]=true -f 'required_status_checks[contexts][]=CI (sqlite3)' -f 'required_status_checks[contexts][]=CI (postgresql)' -f 'required_status_checks[contexts][]=Dependency and static scan' -F enforce_admins=true -F required_pull_request_reviews[required_approving_review_count]=0 -F restrictions=null
   gh api -X PUT repos/techmore/rupert/automated-security-fixes
   ```
5. **Decide the Square environment** (sandbox vs production token) before saving a Square token; the code honours `SQUARE_ENVIRONMENT`.
6. **Google Drive backup**: move the OAuth app out of Testing or add the backup account as a tester; refresh tokens for Testing apps expire after 7 days.
7. **Install the new SER8 units and scripts**: `deploy/rupert-web-ser8.service` inside the container (gives `systemctl reload rupert-web`), the updated `rupert-sync-watch.sh` (set `READY_URL`) and the new `rupert-offhost-backup.{sh,service,timer}` on the host; see the release-process and backup runbooks.
8. **Deploy `main` to SER8** — production is 79 commits behind and these fixes are not live until promoted.
9. **Mobile**: decide whether staff need a native barcode/count app (P2-6) or whether the web scanner pages suffice.
10. **DNS**: retire or re-point `rupert.cybersecuritypilot.org` / `herbalhealers.cybersecuritypilot.org`.
