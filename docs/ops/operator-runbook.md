# Operator runbook

The one page for whoever keeps Rupert running day to day. Commands inside the SER8 Incus container run as the `rupert` user from `/opt/rupert/web` with the production environment loaded (`sudo -u rupert env $(cat /etc/rupert.env | xargs) bundle exec ...` or a shell with `/etc/rupert.env` sourced). Companion documents: [backup and restore](backup-restore-runbook.md), [environment reference](environment-reference.md), [release process](release-process.md), [go-live checklist](go-live-checklist.md), [SQLite and Incus](sqlite-incus.md).

## Daily checks (five minutes, in the morning)

1. `curl -s https://rupert.stoverparc.org/up/ready` → `{"status":"ready",...}`. Any `stale`, `missing`, `low` or `unavailable` is today's first job (table below).
2. Dashboard → **Source sync status** cards: every connected source green with a read in the last 15–30 minutes.
3. **System** page: failed jobs `0` (or explained), worker heartbeat recent, disk/DB size trend sane.
4. **Sync** page: last scheduled run `success`; no run older than 45 minutes still `running`.
5. Yesterday's **Sales** total vs Shopify admin; a glance at **Alerts** for low stock.
6. On Mondays: `systemctl --user list-timers` on the host shows `rupert-offhost-backup.timer` ran; `ls -1t ~/backups/rupert | head -3` is from today.

| `/up/ready` check | Means | Do |
| --- | --- | --- |
| `database: unavailable` | SQLite unreachable or disk full | `df -h`, `journalctl -u rupert-web -n 50`; see restore runbook if the file is corrupt |
| `worker: missing/stale` | Solid Queue worker not heartbeating | `systemctl status rupert-jobs`; `systemctl restart rupert-jobs`; if AppArmor blocks the restart, use the host-side `incus restart rupert` procedure in sqlite-incus.md |
| `last_sync: stale` | no successful sync in 45 min | see "Stuck or failing sync" |
| `disk: low` | < 1 GB free on the DB volume | prune `/var/backups/rupert/frequent` is automatic (24 h); check `web/log`, `tmp/cache`; grow the volume |

## Stuck or failing sync

- A run stuck in `running` for more than 45 minutes is failed automatically by the next scheduler tick (`SyncEngine::STALE_RUN_AFTER`); you do not need to clear it.
- Transient failures (network, timeout, Shopify/Square rate limit or 5xx) retry on their own up to 4 times with backoff. One Buzz message is sent when retries are exhausted; the failed execution stays visible on the System page.
- Credential failures do **not** retry. The Sync page and the Connections page name the category (`credentials`, `entitlement`, `configuration`). Fix the saved credential in Settings/Connections, then **Run full sync**.
- Manual sync: Sync page → *Run full sync* (or per source), or `bundle exec bin/rails ops:sync` / `ops:sync_source[shopify]`.
- Backfill after an outage longer than 48 hours: `bundle exec bin/rails "ops:backfill[7]"` (days). The import is idempotent; nothing is double-counted.
- Shopify "Invalid API key or access token" on the client-credentials token: regenerate the client secret in the Shopify admin → Settings → Apps → Develop apps, save it in Settings, re-run the sync.
- Stock looks wrong for one SKU: Inventory → the variant → check `sourceQuantity` (what Shopify reports) vs `quantity` (clamped at 0). Rupert never changes Shopify stock on its own; correct it in Shopify (or through an owner-approved flow) and the next sync mirrors it.

## Webhooks and GDPR requests

Shopify sends `customers/data_request`, `customers/redact`, `shop/redact`, `app/uninstalled` and `app/scopes_update` to `/api/webhooks/...`. They are HMAC-verified, deduplicated on the delivery id (`webhook_deliveries`, 30 days) and processed by jobs.

- **customers/data_request** writes an `ActivityLog` entry `gdpr_data_request` (Activity page). The merchant must answer the customer within **30 days**: open Customers → the customer → export their profile, orders and interactions, and send it through the channel the customer used. Note the completion in the same Activity page.
- **customers/redact** strips name, email, phone, notes and tags from the mirrored profile and the shipping details of the listed orders automatically. Sales totals are kept.
- **shop/redact** removes the Shopify session; business data is kept until the owner decides on a purge.

## Credential and key rotation

| Secret | Where | How | Side effect |
| --- | --- | --- | --- |
| `SECRET_KEY_BASE` | `/etc/rupert.env` | `bin/rails secret`, replace, `systemctl restart rupert-web rupert-jobs` | everyone is signed out |
| `RAILS_ENCRYPTION_*` | `/etc/rupert.env` | **never swap in place**; add the new key in front of the old (Rails key list), re-encrypt, keep the old key until done; rehearse on a restored copy first | all encrypted columns depend on it |
| Shopify client secret (sync) | Settings → env (`SHOPIFY_CLIENT_SECRET`) | regenerate in Shopify admin, save, run a sync | token cache refreshes itself |
| Shopify API secret (OAuth app) | `SHOPIFY_API_SECRET` in env | rotate in the Partner Dashboard; set `old_secret` in `config/initializers/shopify_app.rb` during the overlap | webhooks use the new HMAC |
| Shopify offline token (`shops` table) | re-install the app | tokens are encrypted at rest; run `bin/rails ops:encrypt_shop_tokens` once after upgrading past 2026-10-20 | — |
| Square access token | Settings → env (`SQUARE_ACCESS_TOKEN`) | create a new token in the Square developer dashboard for the same environment, save, run a Square sync | — |
| Google OAuth / Drive | Settings → Google sign-in and Drive sections | regenerate the client secret in Google Cloud, save; reconnect Drive (consent) | Drive refresh token must be re-issued |
| Off-host backup key | host `~/.config/rupert/offhost.key` | generate a new key, re-encrypt the retained sets (or accept that older sets need the old key, kept in the password manager) | — |
| `SENTRY_DSN` | `/etc/rupert.env` | replace, restart | — |

Every rotation: take a full backup first (`systemctl start rupert-backup.service`), note the date in the Activity page or the operator log.

## Shopify Admin API version upgrade

The version is pinned once in `web/config/shopify_api_version.rb` (the sync client and the OAuth app read it) and must match `[webhooks] api_version` in `shopify.app.toml` (a test enforces this). Shopify releases quarterly and supports each version for a year.

1. Read the release notes for the target version; grep the GraphQL documents in `app/services/catalog_syncer.rb`, `inventory_writer.rb`, `marketing/shopify_discount_api.rb` for removed fields.
2. Change the constant and the TOML, run the test suite.
3. `shopify app deploy` (owner) so webhook subscriptions move to the new version.
4. Deploy; watch the first scheduled sync and the Connections page.

## Onboarding

**A new location (Shopify)**: create it in Shopify; the next sync mirrors it (Locations page). If it should be the primary selling location, set `SHOPIFY_LOCATION_ID` to its gid in Settings → env and run a sync. **Square**: set `SQUARE_LOCATION_ID` the same way. Stock per location shows on Inventory.

**A new staff member**: Users → New. Roles: `employee` (POS and own time records only), `cashier` (sales + customers read), `inventory_employee` (counts and alerts), `manager` (daily operations, no settings/backups/users), `admin` (everything but platform backups), `super_admin` (owner only). Link the user to their Employee record for time clock. Settings, backups, env export/restore and user administration are never reachable by `employee`/`cashier`/`manager` (tested in `navigation_access_boundaries_test.rb`). Off-boarding: Users → Deactivate (sessions die immediately), revoke their API tokens if any.

## Monitoring and alerts

- `/up/ready` is the external uptime signal (database, worker, sync freshness, disk). Point an uptime monitor at it.
- Host watcher `rupert-sync-watch.timer` (outside the container) fails when the newest successful sync is older than 45 minutes, the worker unit is not active, free disk is under 1 GB, or `READY_URL` answers non-200; failures show in `systemctl --user --failed` and Cockpit.
- Buzz (Nostr) messages on sync completion/failure when configured in Settings.
- Sentry when `SENTRY_DSN` is set: every unhandled exception from web and jobs, tagged with the build SHA.
- Rate limiting (`rack-attack`) logs `[rack-attack] throttled ...` lines; a burst of them from one IP is an attack or a broken integration.

## Known limits

Freshness is bounded by the 15-minute poll (no inventory webhooks yet). SQLite means one host and one writer; the sync and the worker are sized for that (`JOB_THREADS=1`). Shopify orders with more than 100 line items are imported with `source_lines_complete=false`. Square OAuth tokens (as opposed to personal access tokens) are not refreshed automatically.
