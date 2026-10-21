# Go-live checklist

Tick every line before Rupert is the system a shift depends on. Owner items are decisions or credentials only the owner can provide; see the audit's "Needs owner" list.

## Code and configuration
- [ ] `main` deployed to SER8 and `curl -sI https://herbalhealers.rupertpos.com/up | grep x-rupert-build` matches the release tag (release process doc).
- [ ] `shopify app deploy` run after merging, so the Partner Dashboard `application_url` and compliance webhook URIs point at `herbalhealers.rupertpos.com` (owner).
- [ ] `/etc/rupert.env` has `HOST`, `SECRET_KEY_BASE`, all three `RAILS_ENCRYPTION_*`, `SHOPIFY_API_KEY/SECRET`, and optionally `SENTRY_DSN` (environment reference doc).
- [ ] Shopify sync credentials saved in Settings (client id/secret, shop domain, `SHOPIFY_LOCATION_ID` if more than one location).
- [ ] Square: token saved only if Square is actually in use; `SQUARE_ENVIRONMENT` matches the token (owner decision).
- [ ] `bin/rails ops:encrypt_shop_tokens` run once after the upgrade that encrypted `shops.shopify_token`.

## Services on SER8
- [ ] `rupert-web.service` installed from `deploy/rupert-web-ser8.service`, `rupert-jobs.service` from `deploy/rupert-jobs-ser8.service`, both `active` with `NRestarts=0`.
- [ ] `rupert-backup.timer` (6 h) and `rupert-backup-frequent.timer` (5 min) active inside the container; `systemctl list-timers` shows next runs.
- [ ] Host: `rupert-sync-watch.timer` active with `READY_URL=https://herbalhealers.rupertpos.com/up/ready`; `rupert-offhost-backup.timer` active and the key provisioned (backup runbook).
- [ ] An external uptime monitor polls `/up/ready` every 5 minutes and pages someone on 503.
- [ ] `GET /up/ready` returns `"status":"ready"` with every check `ok`.

## Data
- [ ] Full sync completed within the last 15 minutes; Dashboard source cards green.
- [ ] A physical sample count of 20 high-turn SKUs matches Shopify and the Inventory page (within the agreed tolerance).
- [ ] Yesterday's sales total in Reports matches Shopify admin for the same day; a test refund shows up on the order within 15 minutes.
- [ ] `bin/restore-drill` run against the production file this week: `DRILL OK`.
- [ ] Off-host backup verified (`sha256sum -c`) and a decrypt test done on another machine.

## People and access
- [ ] One `super_admin` (owner), named `admin`/`manager` accounts, staff on `employee`/`cashier`; no shared logins.
- [ ] Staff confirmed they cannot open Settings, backups or user administration (sign in as a staff account and try).
- [ ] Owner has the password-manager entries: SER8 host, `/etc/rupert.env`, off-host key, Shopify Partner account, Square developer account, Sentry.
- [ ] GitHub: branch protection on `main` requiring CI + Security, Dependabot security updates on (owner; commands in the audit).

## Paper
- [ ] Operator runbook read by whoever is on call; the "stuck sync" and "restore" sections rehearsed once.
- [ ] Privacy notice/terms published if the warehouse portal or any customer-facing page is live (P2 in the audit).
