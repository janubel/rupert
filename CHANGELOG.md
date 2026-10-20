# Rupert changelog

## Unreleased

### Production readiness (2026-10-20)

- **Fix the Shopify GDPR webhooks.** `customers/data_request` and `customers/redact` crashed (route/controller/job names did not match) and all three compliance jobs were empty. They now verify, acknowledge fast, deduplicate on the delivery id, and redact mirrored customer data / record data requests for the operator. First tests for every webhook endpoint.
- **Refunds and cancellations reach Rupert.** Orders are fetched by `updated_at` on both platforms and Shopify/Square refunds become `Core::Refund` rows, so a refund issued days after the sale no longer overstates revenue.
- **Money is decimal.** Every amount conversion goes through `Money` on `BigDecimal`; typed refund/opening-cash amounts are validated.
- **Platform clients retry** rate limits (including Shopify `THROTTLED` with cost-based waits), 5xx and connection failures with bounded backoff; `SyncJob` retries transient failures and alerts once when it gives up.
- **Request throttling** (`rack-attack`) on login, signup, webhooks, the bearer API, public portals and the secret-bearing settings endpoints. **Optional Sentry** error tracking via `SENTRY_DSN`.
- **Encrypted Shopify offline tokens** (`ops:encrypt_shop_tokens` re-encrypts existing rows).
- **`GET /up/ready`**: database, worker heartbeat, sync freshness and disk in one readiness signal; the host watcher checks disk and the endpoint.
- **SQLite pragmas** (foreign keys, bounded WAL, cache) and a web-vs-job write-contention test.
- **Backups**: `bin/restore-drill` proves restore end to end with measured times; the off-host copy is encrypted, verified and shipped as a host timer; a backup/restore runbook states RPO/RTO.
- **Docker image builds and boots again** (build-time dummy secrets, explicit `HOST` requirement, bash on Alpine).
- **Shopify configuration**: API version pinned once (`config/shopify_api_version.rb`, checked against `shopify.app.toml`), `application_url` moved off a dead host, no built-in shop-domain default.
- **Repository hygiene**: `legacy/` (44 Dependabot alerts) and droplet-era units removed; `deploy/rupert-web-ser8.service` added; CI gains coverage floors on the sync engine and money paths, a whitespace check and a pinned artifact upload.
- **Docs**: operator runbook, backup/restore runbook, environment reference, release process, go-live checklist and the production readiness audit.

- Add an **in-app update check**. Admins who manage settings see an "Update available" banner when GitHub `main` has newer changes than the running build, with the newest change title and a link to what changed; it can be dismissed per build. The comparison runs in a background job, is cached for six hours, never installs anything and fails silently when offline. Disable with `RUPERT_UPDATE_CHECK=off`.
- Show a **1% commission and staff 50%-off card bonus** on timesheets. Each timesheet now carries credited sales and card-redemption counts; the detail, list and CSV views display commission (1% of credited sales), the card bonus ($10 per redemption) and the compensation total. These are display figures only and are not posted to payroll. Demo timesheets provision fictional sales and redemptions under the existing payroll-excluded demo marker.
- Dramatically enhance the **POS preview** at `/point_of_sale`: **barcode quick-add** (scan a barcode or type a SKU — a single match joins the cart, several jump to catalog search), **instant search** that filters as you type, keyboard shortcuts (`/` focuses search, `b` the scan field), **optimistic totals** that keep showing the last checked amounts while prices re-check with a badge when a price moved, **one-tap tip presets**, and **Copy quote** / **Print quote** to hand a checked preview to the register. A catalog-readiness panel surfaces the Shopify pull freshness and conflicting SKUs up front. Still strictly preview-only: no sale, payment, receipt or stock reservation is created.
- Add **duplicate review** to bank reconciliation (completes F40): the workbench now flags statement lines that share an amount within the date window as possible duplicates, with a one-click ignore. Ignored lines drop out of reconciliation and duplicate detection.
- Add **ledger export** (F40): download posted journal entries at `/finance/ledger_export` as QuickBooks IIF (general journal) or an accountant-friendly CSV with per-line debits/credits, for import into QuickBooks, Xero, Wave, Sage and similar. Exports only posted entries in the chosen range; voids are excluded.
- Add **ledger export** (F40): download posted journal entries at `/finance/ledger_export` as QuickBooks IIF (general journal) or an accountant-friendly CSV with per-line debits/credits, for import into QuickBooks, Xero, Wave, Sage and similar. Exports only posted entries in the chosen range; voids are excluded.
- Add **manual journal entries** and **GL period locks** (completes the F39 close). Accountants can post a balanced manual entry — an adjustment, accrual, opening balance or owner draw — at `/finance/journal_entries/new`; debits must equal credits, enforced on save. The general ledger now honors period locks: an entry dated inside a locked month, quarter or year cannot be created or voided until the period is reopened on the Books desk.
- Add **bank reconciliation** (roadmap F40): a workbench at `/finance/bank_reconciliation` that matches uploaded bank-statement lines to general-ledger Cash/Checking movements by sign, amount and date, with one-click confirm/clear. Surfaces the statement-vs-ledger difference and the unmatched items on each side (money that moved in the bank with no ledger entry, and ledger movements absent from the statement). Matching is a suggestion only — nothing is applied without a person.
- Add a **double-entry general ledger** (roadmap F39). Balanced `journal_entries`/`journal_lines` (debits always equal credits, enforced on save) post idempotently from completed sales, expenses and vendor payments, with void-and-repost on edit or removal. Expenses gain an optional GL account (defaulting from category). New **General ledger** (`/finance/journal_entries`) and **Financial reports** (`/finance/reports`) pages produce a Trial balance, Income statement and Balance sheet from posted entries, with CSV export. Backfilled the existing sales history into the ledger.
- Add the **Books desk** (`/books`), one front door for money cleanup. Each finished day shows six ordered steps (sales in, registers match, follow-ups, reviewed, closed, approved) with a single "do this next" action, oldest day first. Last week gets a chores checklist (bank statement, undecided bank lines, money out, overdue follow-ups, weekly approval). Days of the current week wait for the weekly sign-off instead of asking for daily approvals. The housekeeping audit loads lazily.
- Add month, quarter and year end checklists and **period locks** (`/books/locks`). Locking a finished period stores a fingerprint of its totals and retains a dated JSON archive. Expenses, vendor payments, bank-line decisions, day reviews, close packages and approvals dated inside a locked period then cannot be added, changed, moved or removed. Locks and reopenings are kept in a hash-chained ledger; reopening needs settings access and a written reason. Source imports that change a locked period are flagged on the lock page and in the books check.
- Money reconciliation reports add quarterly and yearly periods, retained automatically on the first of each quarter (12:35 a.m.) and on January 1 (12:40 a.m.) Eastern.
- Group the Money workspace navigation into Routine, Records and Reports, and add Bank statements and Locked periods to it.
- Bank statement review: progress bar, "Use suggestions" to pre-fill recognised payees (still saved only by a person), a sticky save bar with a live count, and a warning before leaving with unsaved choices.

- Phone layouts: the page guide no longer auto-opens on narrow screens (it filled the first screen), Inventory shows each variant's Shopify/POS counts under its name (the table is wider than the page at every size), and Accounts shows each person's role, status and Edit link under their name, because those columns scroll out of view.
- Stop the Sales, Reports and Settings pages from scrolling sideways on phone-width screens: filter rows wrap, the reports tab strip scrolls inside its pill, grid items may shrink so wide charts no longer stretch the page, and long redirect URLs break.
- Show a read-only notice on Inventory when Shopify reports negative (oversold) stock for variants; displayed quantities are unchanged and nothing is written to Shopify.
- Keep the platform-reported Shopify quantity (`InventoryLevel.sourceQuantity`) next to the clamped mirror count so oversold stock is visible; the clamped `quantity` and every existing reader are unchanged. Also regenerate `db/schema_sqlite.rb`, which was missing the per-tenant `WarehouseTier.tenantId` column.
- Dashboard stat cards size their figures to the card so large amounts no longer overflow on phones, and the month revenue caption now shows a formatted dollar amount.
- Follow Shopify variant, location and per-item inventory-level connections to exhaustion so products with more than 100 variants or stores with many locations are no longer silently truncated.
- Correct inventory stock-map caching across searches and batch variant loading to remove per-product queries.
- Add measured tenant timeline indexes for the last-sync lookup and customer list, with stable customer pagination for timestamp ties.
- Publish isolated SER8 SQLite read/write, inventory-query and WAL contention measurements with reproducible research harnesses.

- Publish a shared 49-feature catalog, delivery roadmap and sourced 14-competitor / 32-capability matrix on GitHub Pages, with search filters and CSV/JSON downloads.
- Add the signed-in Features & roadmap page and SQLite configuration, library and WAL diagnostics on System health.
- Add explicit SQLite planner maintenance tasks and a one-thread SQLite worker default, configurable with `JOB_THREADS`.
- Reconcile documented SER8 SQLite cutover status, fix unsafe stale-database rollback guidance, and document Incus recovery, backup checks and scaling alternatives.
- Check generated site consistency and local documentation links in CI.

- Add `db:postgres_to_sqlite` and `bin/migrate-to-sqlite` to copy a live PostgreSQL database into SQLite with verified
  row counts, and SQLite support in `bin/backup.sh`. Runbook: `docs/ops/sqlite-migration.md`.
- Reorganize `docs/` (plans, research, audit data, index) and remove dead scaffolding (`.gitmodules`, empty `extensions/`).
- UI: shared `.page-title`, `.empty-row` and `.flash` components, skip-to-content link, `main` landmark target.

## 0.2.0 — 2026-10-03

- Add opt-in SQLite support with FTS5 trigram search for local performance evaluation. PostgreSQL remains the production default.
- Cache global search results by tenant, user, and HR permission so results cannot cross tenant boundaries.
- Update Rails to 8.1.4, Shopify CLI to 4.8.4, and compatible patch/minor Ruby dependencies.
- Repair the CI workflow so the repository's tracked lockfiles no longer stop checks before they run.
- Require an explicit PostgreSQL password in the optional Docker Compose and backup paths; remove the unsafe `rupert` password fallback.
- Update deployment documentation to reflect the live SER8/Incus host and mark legacy systemd instructions as outdated.

## 0.1.0

- Initial Rupert application release.
