# Rupert

Centralized inventory operations: a Shopify + Square sync
engine with an Oatmeal-styled web dashboard, backed by SQLite in production. Runs as a
Ruby on Rails 8.1 app (based on the
[Shopify Ruby app template](https://github.com/Shopify/shopify-app-template-ruby))
and is currently hosted at [rupert.stoverparc.org](https://rupert.stoverparc.org/).

```
Shopify ──┐                     ┌── Dashboard
          │                     ├── Inventory
Square ───┼── sync engine ──▶ SQLite DB     ──▶ GUI
          │   (Rails jobs)     │      (Rails + Tailwind)
          └────────────────────┴── Settings (env, backup/restore)
```

## What's here

| Path | Purpose |
| --- | --- |
| `web/` | The Rails 8.1 app: sync engine services, Oatmeal GUI, JSON APIs |
| `legacy/` | The original Node/React implementation, kept as reference |
| `docs/` | Docs site, plans, audits and research (see `docs/README.md`) |
| `deploy/` | Old droplet systemd units, kept for reference only (see below) |
| `bin/` | Host scripts (`backup.sh`) |
| `shopify.app.toml` | Shopify app config (scopes, webhooks) |
| `Dockerfile`, `docker-compose.yml` | Optional container deployment |

## Local development

Requirements: Ruby 4.0.6 (rbenv), Bundler, PostgreSQL 16, Node (for the
Shopify CLI).

```bash
bundle install          # from web/
cp .env.example .env    # fill in credentials at repo root
# create the postgres role/db (or set POSTGRES_* env vars):
#   createuser -s rupert && createdb -O rupert rupert_development
bin/rails db:create db:migrate   # from web/
bin/rails db:import_legacy       # one-time: pull data from legacy/prisma/dev.sqlite
bin/rails db:sqlite_to_postgres  # one-time: migrate production.sqlite3 -> PG
bin/rails tailwindcss:build
bin/rails server        # http://localhost:3000
```

The `.env` at the repo root is loaded at boot (Dotenv) and holds the sync
engine credentials (`SHOPIFY_CLIENT_ID/SECRET`, `SQUARE_ACCESS_TOKEN`, …).
The Shopify OAuth pair (`SHOPIFY_API_KEY`/`SHOPIFY_API_SECRET`) comes from
`shopify app info --web-env` when developing through the Shopify CLI, or is
set in the production environment.

## Operations

For the current daily-use limits and the next payment/inventory rollout gates, start with [Derrick's day-to-day pickup plan](docs/ops/day-to-day-readiness.md).

```bash
bin/rails ops:sync                    # full Shopify + Square mirror sync
bin/rails ops:sync_source[square]     # single source
bin/rails ops:catalog_links           # print catalog link stats (linked/matched/mismatched)
bin/rails ops:push_guard:status       # freeze + approval-window state per platform
bin/rails ops:push_guard:freeze[square,reason]   # record a maintenance freeze (awareness only)
bin/rails ops:push_guard:unfreeze[square]
bin/rails test                        # page + API smoke tests
```

Scheduled syncs run through Solid Queue (`bin/jobs`) — every 15 minutes in
production, scheduled in `config/recurring.yml`.

## Write safety

The sync loop is a read-only mirror: it never writes quantities or SKUs to
Shopify or Square on its own. The old automatic lock-step machinery
(reconcile-plan apply, shared-pool push) was removed in August 2026 when the
operating model changed: Shopify and Square are separate locations serving the
same items from independent inventories, so equalizing them was wrong.

Outbound stock writes now happen only through explicit, owner-approved flows
(size-family derives, remediation tasks). Per owner directive (2026-08-18) the
former `PlatformPushGuard` approval-window enforcement is a no-op — freezes and
windows are recorded for operator awareness only. The standing rule is:
**always ask the owner before any data-mutating action on Shopify or Square,
and never write SKUs without explicit sign-off.**

## GUI pages

- **Dashboard** — per-user customizable widgets (key stats, per-channel
  revenue, attention, stock alerts, sync/reconcile history)
- **Sales** — daily sales journal in spreadsheet style: an hourly × location
  pivot plus every sale of the day in arrival order
- **Customers** — unified CRM view (searchable, Ransack + Pagy)
- **Inventory** — products/variants with stock held at each location (Shopify
  and Square locations side by side, per platform totals, and a catalog
  identity chip); the "Download PDF" button (`/inventory/pdf`) exports a
  printable snapshot with per-platform last-sync timestamps and summary totals
- **Catalog Links** (`/reconcile`) — read-only SKU identity audit between
  platforms: linked items, matched/mismatched SKUs, one-sided counts. Quantity
  differences across locations are normal and shown, never "corrected"
- **Ledger** — transaction mirror from both platforms
- **Alerts** — low-stock flags turned into restock decisions: per-location
  on-hand, 14/30-day sales pace across channels, days of cover, and a
  suggested reorder quantity (~30 days of cover at recent pace). Open alerts
  sort by urgency; resolve/ignore as before. Advice only — nothing is ordered
  or written automatically
- **Sync** — run syncs, view run history and logs
- **SwipeSimple** — import sales from a SwipeSimple CSV export (no public API) into the canonical sales stream
- **Connections** — plain-language guide to every service's keys: what's set, where to find each, and how to renew
- **Settings** — `.env` import/export (JSON API included) and DB backup/restore:
  - `GET /settings/env.json` · masked env keys
  - `POST /settings/env_import` · body `{ "text": "KEY=VALUE\n…" }`
  - `GET /settings/env_export` · full `.env` text
  - `GET /settings/backup` · consistent adapter-aware snapshot (SQLite or PostgreSQL)
  - `POST /settings/restore` · multipart `file` upload
- **Team / People (HR)** — full employee lifecycle:
  - **Employees** · HR records with department, position, and status lifecycle
  - **Departments** · org chart (manager, headcount)
  - **Positions** · job titles and pay grades
  - **Timesheets** · weekly hours with submit / approve / reject workflow
  - **Leave & PTO** · requests, approvals, and annual balances
  - **Payroll** · pay runs built from approved timesheets and pay rates

ERP pages require a Rupert login. Password login and configured Google OAuth are supported; Shopify OAuth remains available for store integration.

## ERP architecture

Rupert is a modular monolith growing into a full ERP for small businesses.
Extensions live under `app/modules/<name>/` and register themselves in
`app/models/module_registry.rb` (nav + permission gate). The canonical domain
core lives in `app/modules/core/` (`Customer`, `Order`, `OrderLine`,
`Payment`) and is fed by the Shopify/Square sync engine through
`CanonicalOrderImporter` — a clean seam between the source mirrors
(`ShopifyProduct`, `LedgerEntry`, …) and the unified ERP model. A third,
manual source (`SwipesimpleImporter`) feeds CSV exports through the same seam.

- Roles: `super_admin`, `admin`, `manager`, `cashier`, `reader` with a
  permission matrix in `User::ROLE_PERMISSIONS` and Pundit policy objects
- Dashboards: per-user widget layout saved as JSON on `User#dashboard_config`
- Sales grid: `SalesController` builds an hourly × location pivot from
  `Core::Order` (`groupdate`-ready time series)
- HR: `app/modules/people/` (employees, departments, positions, timesheets,
  leave & PTO, payroll) with `PayrollCalculator` turning approved timesheets
  into payslips
- DB: SQLite with FTS5 search runs in production as recorded by the October 13 cutover report. PostgreSQL remains the default for unconfigured environments; CI covers both adapters. See `docs/ops/sqlite-incus.md` for tuning, recovery and scaling triggers.

## Production and deployment

Production is hosted on SER8 in Incus and served at
[rupert.stoverparc.org](https://rupert.stoverparc.org/). GitHub is the source
repository; pushing a commit or creating a GitHub release does not deploy it.

The SER8-specific worker/backup units and host freshness watcher are under `deploy/`. Older droplet units are reference material; do not substitute them for the Incus layout.

The cutover report records production SQLite as of **2026-10-13** (78,573 rows, 61 tables verified). Live hosting and the October 14 application deployment were verified; see the [deployment receipt](docs/ops/deployment-2026-10-14.md). Read [SQLite and Incus operations](docs/ops/sqlite-incus.md) and the [cutover report](docs/ops/sqlite-migration.md). The PostgreSQL copy is frozen at cutover; switching back after new SQLite writes requires reconciliation.

## Features, roadmap and comparison

- [Public roadmap](https://techmore.github.io/rupert/roadmap.html) — implemented scope, implementation evidence, delivery phases and acceptance gates.
- [Competitor matrix](https://techmore.github.io/rupert/competitors.html) — scoped ERP, inventory and POS comparisons, official sources and CSV/JSON downloads.
- [Private owner checklist guide](https://techmore.github.io/rupert/owner-checklists.html) — administrator-only local attestations, evidence/history and private printing; no checklist contents are published.
- Signed-in **System → Features & roadmap** (`/roadmap`) shows the same catalog. Planned items are not enabled.
- `web/config/product_roadmap.json` is the canonical catalog. Run `bin/build-product-site` after changing it; `--check` detects drift in CI.
- `bin/rails ops:sqlite:report` reads SQLite settings/space metrics; `bin/rails ops:sqlite:optimize` explicitly refreshes planner statistics. SQLite job concurrency defaults to one thread (`JOB_THREADS` can override).

## Data model

Mirrors the legacy Prisma schema (table/column names preserved for import
compatibility): `ShopifyProduct`, `ShopifyVariant`, `SquareItem`,
`SquareVariation`, `SkuLink`, `ReconcileRun`, `ReconcileItem` (historical run
records; no longer written), `Location`,
`InventoryLevel`, `InventoryMovement`, `StockAlert`, `SyncRun`,
`InventoryPolicy`, `LedgerEntry`, plus Shopify session storage (`shops`,
`users`) and app `settings`.

## Known caveats

- **Client-credentials token**: the Shopify sync uses the store's
  client-credentials token (`SHOPIFY_CLIENT_ID`/`SECRET`). If the token is
  rejected (`[API] Invalid API key or access token`), re-install the app on
  the store or regenerate the secret in the Shopify admin — the sync will
  fail loudly in the Sync page until then.
- **SQLite** is the recorded production database; PostgreSQL remains supported for development and scaling alternatives. Mirror/journal tables are pruned
  nightly by `DataRetentionJob`; canonical business data is never pruned.
- **Shopify and Square are separate locations with independent inventories.**
  The sync is a read-only mirror; nothing equalizes quantities across them.
  Outbound stock writes happen only through explicit, owner-approved flows,
  and SKU writes always require owner sign-off first.

- [SwipeSimple reporting investigation and hourly SER8 CSV intake](docs/ops/swipesimple-reporting.md) — verified native formats, encrypted source provenance, invoice identity limits, operational setup and remaining vendor access requirements.
- [SwipeSimple integration research and long-term Valmar / Authorize.net objective](docs/ops/swipesimple-integration-research.md) — supported-feed options, ACH/reporting gaps, QuickBooks and partner-access limits, source evidence and the vendor questionnaire; roadmap F64 records the owner's direction.
