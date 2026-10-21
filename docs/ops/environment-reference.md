# Environment reference

Two kinds of configuration exist. **Boot-time variables** live in `/etc/rupert.env` on SER8 (read by systemd before dropping privileges) or in the repo-root `.env` in development; they are needed before the database can be opened. **Managed settings** are stored encrypted in the `settings` table and edited from Settings → Environment (or imported as `.env` text); they override the process environment for the same key and are what you normally change day to day.

## Boot-time variables (`/etc/rupert.env`)

| Variable | Required | Purpose |
| --- | --- | --- |
| `RAILS_ENV` | yes | `production` |
| `HOST` | yes | Public origin, e.g. `https://rupert.stoverparc.org`. Enables host authorization (the app refuses to boot without it) and builds OAuth callbacks |
| `ADDITIONAL_HOSTS` | no | Comma-separated extra hostnames allowed by host authorization |
| `SECRET_KEY_BASE` | yes | Session/cookie signing. `bin/rails secret` |
| `RAILS_ENCRYPTION_PRIMARY_KEY`, `RAILS_ENCRYPTION_DETERMINISTIC_KEY`, `RAILS_ENCRYPTION_KEY_DERIVATION_SALT` | yes | Active Record encryption for every credential and document column. Generate once with `bin/rails db:encryption:init`; **never change without re-encrypting** |
| `RUPERT_SQLITE_DATABASE_PRODUCTION` | no | Path of the SQLite file (default `storage/production.sqlite3`) |
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
| `RUPERT_BUILD_SHA`, `RUPERT_BUILT_AT` | Docker only | Build identity for git-free deployments |
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
| `FULFILLMENT_ALERT_HOURS` | Unfulfilled-order alert threshold |
| `PUSH_GUARD_*`, `PUSH_FREEZE_*` | Informational freeze/approval state (no longer enforced) |

Masked values are visible at `GET /settings/env.json`; a full export needs the password again and is logged. Imports and exports are audit-logged and rate-limited.
