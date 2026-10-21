# Environment reference

Two kinds of configuration exist. **Boot-time variables** live in `/etc/rupert.env` on SER8 (read by systemd before dropping privileges) or in the repo-root `.env` in development; they are needed before the database can be opened. **Managed settings** are stored encrypted in the `settings` table and edited from Settings → Environment (or imported as `.env` text); they override the process environment for the same key and are what you normally change day to day.

## Boot-time variables (`/etc/rupert.env`)

| Variable | Required | Purpose |
| --- | --- | --- |
| `RAILS_ENV` | yes | `production` |
| `HOST` | yes | Public origin, e.g. `https://herbalhealers.rupertpos.com`. Enables host authorization (the app refuses to boot without it) and builds OAuth callbacks |
| `ADDITIONAL_HOSTS` | no | Comma-separated extra hostnames allowed by host authorization |
| `RUPERT_LEGACY_HOSTS` | no | Comma-separated retired hostnames (production: `rupert.stoverparc.org,rupert.cybersecuritypilot.org,herbalhealers.cybersecuritypilot.org`). Requests to them are redirected to `HOST` with the same path (301 for GET/HEAD, 308 otherwise); `/up` health checks are still answered. They do not need to be in `ADDITIONAL_HOSTS` |
| `SECRET_KEY_BASE` | yes | Session/cookie signing. `bin/rails secret` |
| `RAILS_ENCRYPTION_PRIMARY_KEY`, `RAILS_ENCRYPTION_DETERMINISTIC_KEY`, `RAILS_ENCRYPTION_KEY_DERIVATION_SALT` | yes | Active Record encryption for every credential and document column. Generate once with `bin/rails db:encryption:init`; **never change without re-encrypting** |
| `RUPERT_SQLITE_DATABASE_PRODUCTION` | no | Path of the SQLite file (default `storage/production.sqlite3`) |
| `RUPERT_SQLITE_DATABASE_DEVELOPMENT`, `RUPERT_SQLITE_DATABASE_TEST` | no | Per-environment SQLite paths; defaults are under `storage/` |
| `DATABASE_URL` | must be unset | Any nonempty value is rejected, including a SQLite URL. Configure the database with the `RUPERT_SQLITE_DATABASE_*` path variables instead. |
| `RUPERT_DB_ADAPTER` | no | Omit it; legacy value `sqlite3` is accepted. Any other explicit adapter value is rejected. |
| `SQLITE_BUSY_TIMEOUT_MS` | no | Writer wait before `SQLITE_BUSY` (default 5000) |
| `RAILS_MAX_THREADS` / `RAILS_MIN_THREADS` | no | Puma threads and AR pool (default 5) |
| `WEB_CONCURRENCY` | no | Puma workers (unset: single process, right for SER8) |
| `PORT` | no | Puma port (3000) |
| `JOB_THREADS` | no | Solid Queue worker threads (default 1: SQLite has one writer) |
| `JOB_CONCURRENCY` | no | Solid Queue worker processes (default 1) |
| `RAILS_LOG_LEVEL` | no | `info` (default) or `debug` |
| `RAILS_LOG_TO_STDOUT` | no | `1` to log to journald/stdout |
| `RAILS_SERVE_STATIC_FILES` | no | `1` when no proxy serves `public/` |
| `SHOPIFY_API_KEY`, `SHOPIFY_API_SECRET` | yes | The Partner app credentials: OAuth and webhook HMAC |
| `SCOPES` | no | OAuth scopes (default matches `shopify.app.toml`) |
| `SHOP_CUSTOM_DOMAIN`, `SHOPIFY_APP_PRIVATE_SHOP` | no | Shopify app template options; unused on SER8 |
| `SENTRY_DSN` | no | Enables error tracking; `SENTRY_ENVIRONMENT` (default `production`), `SENTRY_TRACES_SAMPLE_RATE` (default 0) |
| `RUPERT_UPDATE_CHECK` | no | `off` disables the in-app "update available" banner |
| `RUPERT_AUTODEPLOY_STATE` | no | Where System → Updates reads the updater's `status.json` (default `/var/lib/rupert-autodeploy`); must match the updater's |
| `RUPERT_AUTODEPLOY_INBOX` | no | Where System → Updates leaves install requests and the manual-mode flag (default `web/storage/autodeploy`); must match the updater's and `rupert-autodeploy.path` |
| `RUPERT_BUILD_SHA`, `RUPERT_BUILT_AT` | Docker only | Build identity for git-free deployments |
| `RUPERT_INITIALIZE_DATABASE` | Compose first start only | Set to `1` only to explicitly initialize a genuinely new empty SQLite database; remove it after successful initialization. Otherwise Compose requires a nonempty existing SQLite file. |
| `REDIS_URL` | compose only | Action Cable in the optional Docker Compose layout |
| `SECRET_KEY_BASE_DUMMY` | build only | Set by the Dockerfile during asset precompile; never at runtime |

## Managed settings (Settings → Environment, encrypted in the database)

| Key | Purpose |
| --- | --- |
| `SHOPIFY_CLIENT_ID`, `SHOPIFY_CLIENT_SECRET` | Client-credentials token for the sync engine (custom app in the store's admin) |
| `SHOPIFY_SHOP_DOMAIN` | `your-store.myshopify.com`; falls back to the workspace record, never to a built-in default |
| `SHOPIFY_LOCATION_ID` | gid of the primary selling location (optional) |
| `SQUARE_APPLICATION_ID`, `SQUARE_ACCESS_TOKEN`, `SQUARE_ENVIRONMENT` (`production`/`sandbox`), `SQUARE_LOCATION_ID` | Square read access; a saved token turns the Square sync on |
| `SQUARE_SANDBOX_APPLICATION_ID`, `SQUARE_SANDBOX_ACCESS_TOKEN` | Sandbox pair for testing |
| `SYNC_MINUTES` (informational; schedule is `config/recurring.yml`), `SYNC_HISTORY_DAYS` (first-sync lookback, default 30) | Sync window |
| `AUTHORIZE_NET_LOGIN_ID`, `AUTHORIZE_NET_TRANSACTION_KEY`, `AUTHORIZE_NET_CLIENT_KEY`, `AUTHORIZE_NET_SANDBOX` | Card payments for warehouse sales |
| `GOOGLE_PAY_*`, `APPLE_PAY_*` | Wallet buttons on the warehouse checkout |
| `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET` | Google sign-in |
| `GOOGLE_DRIVE_CLIENT_ID`, `GOOGLE_DRIVE_CLIENT_SECRET`, `GOOGLE_DRIVE_REFRESH_TOKEN`, `GOOGLE_DRIVE_FOLDER_ID`, `GOOGLE_DRIVE_RETENTION` | Instance backups to Drive (platform administrator only) |
| `BUZZ_RELAY_URL`, `BUZZ_PRIVATE_KEY`, `BUZZ_CHANNEL`, `BUZZ_ANNOUNCEMENTS_CHANNEL`, `BUZZ_INV_ADJUSTMENTS_CHANNEL`, `OPCODE_BUZZ_PRIVATE_KEY` | Buzz (Nostr) notifications |
| `BUZZ_CHAT_LINK_TEMPLATE`, `BUZZ_CONNECT_LINK_TEMPLATE`, `BUZZ_DOWNLOAD_MACOS`, `BUZZ_DOWNLOAD_WINDOWS`, `BUZZ_DOWNLOAD_LINUX`, `BUZZ_DOWNLOAD_IOS`, `BUZZ_DOWNLOAD_ANDROID`, `BUZZ_WEB_URL` | Links on the Buzz card (open chat, add workspace and QR, per-platform downloads); defaults and rules in [buzz.md](buzz.md) |
| `FEEDBACK_READY_SENDERS` | Who may mark chat reports "ready for development": comma, space or newline separated 64-hex Nostr public keys or `npub…` values (Settings → Environment). Empty means nobody; reports are then always for review. See `docs/ops/feedback-reports.md` |
| `FULFILLMENT_ALERT_HOURS` | Unfulfilled-order alert threshold |
| `PUSH_GUARD_*`, `PUSH_FREEZE_*` | Informational freeze/approval state (no longer enforced) |

Masked values are visible at `GET /settings/env.json`; a full export needs the password again and is logged. Imports and exports are audit-logged and rate-limited.
