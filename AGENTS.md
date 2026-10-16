# Shopify app development

## NAB / IRIS reporting continuity

Read `docs/ops/iris-reporting.md` before continuing IRIS work. Use its verified tenant OpenAPI contract, not the older SDK deposit examples. The merchant portal login has no visible API Settings tab; live API access and native Health Center CSV bytes remain unverified. Store secrets only in encrypted connection settings. Keep real MIDs, statements, report exports and session data out of public Git. Reports and monthly summaries are separate tenant-scoped snapshots; never sum overlapping windows or create duplicate sales from them.

Also read `docs/ops/iris-integration-investigation.md`. A native Daily Deposits CSV and the funding reference PDF were downloaded and inspected privately; Health Center native bytes remain unverified. Daily Deposits files have a separate native importer, explicit merchant/month context and `daily_deposits_csv` snapshot kind; do not send them to the monthly-summary parser. Do not interpret that download as API entitlement or native Health Center compatibility.

Automatic Daily Deposits website pulls use `reporting_auth_mode=web`, encrypted NAB login fields, independent ephemeral sessions and merchant/CSV row/total checks. REST API jobs accept `api_key` mode only. Never reuse browser session state. Read `docs/ops/iris-automatic-deposits-deployment-2026-10-15.md` before deploying or changing the scheduler.

This app is scaffolded from a Shopify app template. See the README for framework-specific details.

Use the [Shopify AI Toolkit](https://shopify.dev/docs/apps/build/ai-toolkit) for all Shopify API and platform work. If missing, install it in the agent host per that page (or `npx skills add Shopify/shopify-ai-toolkit --list` for skill-compatible hosts) — do not add tooling to this repo.

## Hard rules (do not violate)

- **The push guard is REMOVED (owner directive, 2026-08-18).** `PlatformPushGuard.authorize!` is a no-op: no outbound write is blocked by approval windows or the maintenance freeze. Freeze/approve/status remain only as read-only operator info. The replacement safeguard is the rule below.
- **ALWAYS ASK before any data-mutating action on Shopify or Square** — creating/updating products, pushing inventory, or writing SKUs. Do not apply without explicit owner sign-off first. Syncs (read-only mirrors into the local DB) are fine to run without asking.
- **Square can still be frozen any time for maintenance via `ops:push_guard:freeze[square,reason]`** — this now records state for awareness but no longer blocks writes; check `ops:push_guard:status`.
- **SKU changes require explicit owner sign-off before writing** to Shopify or Square. You may plan and inspect freely, but never write SKUs without asking.

## C-Trax integration context

- The owner selected C-Trax as the retail physical-count reference on 2026-10-15. Read `docs/ctrax.md` before changing its connector.
- C-Trax user authentication and TRX merchant credentials are separate. Never use a merchant client ID/token/algorithm as guessed stock API authentication.
- Keep native store/variant IDs when source SKUs are absent. Preserve signed stock, distinguish missing stock from zero, and never write counts back to a platform without owner authorization.
- Real exports, private deployment/access notes, credentials and browser sessions do not belong in this public repository. Keep private backups in an owner-verified private destination. Do not extract hidden browser session storage or cookies.
