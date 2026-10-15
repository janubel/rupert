# SER8 Rupert deployment — October 15, 2026

Verified approximately 8:37–8:40 AM America/New_York (12:37–12:40 UTC) on the live Rupert Incus instance on SER8.

## Release

The previous application release was `74ef4d7726feb78ec87516abed21a6968f5f086d`. The deployed application release is `85d87fe5f4eadf614ff43c59d6bf68545f85d997`, including [workflow PR #21](https://github.com/techmore/rupert/pull/21) and [provider setup PR #22](https://github.com/techmore/rupert/pull/22). Main-branch CI passed on SQLite and PostgreSQL, and Pages published the updated source.

The release adds scanner counts, local stock reservations, bulk-material lot movements, worker clock/corrections, employee roles, daily register summaries, a scoped read API, POS/tip and commission previews, and provider account preparation. KORONA/Cova have dedicated-credential setup and explicit documented read checks; Valmar/PAX/C-Trax retain vendor/gateway prerequisites, SwipeSimple uses CSV, and the existing Shopify/Square paths remain separate. No merchant account, terminal or live payment was activated.

## Recovery and migration rehearsal

A fresh consistent SQLite backup and private configuration/service definitions are retained in `/var/backups/rupert/pre-pos-3g2LDO12`. A compressed copy was restored to a separate file and compared byte-for-byte. All six pending migrations were applied, rolled back to `20261014200000`, and reapplied on that copy. All 72 prior tables retained their row counts. Ten new tables were added, with final schema version `20261015130000`. Integrity checks returned `ok`; foreign-key checks reported zero violations.

A second consistent database copy was taken immediately before live promotion. Incus snapshot `pre-pos-20261015-952bd9c` was retained. Backup contents include secrets and are private; they are not published. The retained PostgreSQL cutover database remains frozen and must not replace the active SQLite database without reconciliation.

The first live migration command stopped before migration because newly checked-out source files inherited the restrictive backup umask. Application-group read/traverse permissions were restored on the release source and Git metadata, then the migration succeeded. Private backup/configuration permissions remained restricted. Bundler dependency checking, Rails eager loading, Tailwind/asset compilation and explicit SQLite planner optimization passed. Activation used host-side `incus restart rupert`, following the existing AppArmor restart guidance.

## Observed after restart

| Check | Result |
| --- | --- |
| Deployed application release | `85d87fe5f4eadf614ff43c59d6bf68545f85d997` |
| Production checkout | Clean |
| `/up` and `/login` | HTTP 200 |
| Signed-out roadmap, provider setup, POS preview, time clock and bulk routes | HTTP 302 to login |
| `/api/v1/catalog` without a bearer token | HTTP 401 |
| Web, jobs and local backup timer | Active |
| Service restart counters | 0 |
| Actual worker processes | One supervisor, dispatcher, worker and scheduler |
| SQLite / final migration | 3.53.2 / `20261015130000` |
| Integrity / foreign keys | `ok` / zero violations |
| Feature catalog | 58 entries |
| Canonical orders / Shopify variants | 2,673 / 842 |
| Ready / failed jobs | 0 / 1 (pre-existing failure count unchanged) |
| Latest successful scheduled sync at verification | 8:30 AM EDT, before activation |
| Provider setup rows / issued API tokens | 0 / 0 |
| New scan receipts, reservations, bulk materials and clock shifts | 0; no test business data inserted |
| Herbal Healers domain / requested store administrator | Allowed / active admin verified |
| Public connection guide and roadmap | HTTP 200; 58-feature catalog served |

## Validation and practical limits

SQLite passed 520 tests with 2,844 assertions. PostgreSQL passed 520 tests with 2,829 assertions and two SQLite-only skips. The local macOS pg extension crashed during forked startup, so the local PostgreSQL rerun was serial; the normal Linux parallel CI also passed. RuboCop inspected 388 files without offenses. Generated-site and 13-page link checks passed. Synthetic local browser checks verified workflow screens, cart/tip calculation, clock-in/out, bulk movements, local holds, provider setup persistence, credential fields and console health.

Production browser checks exercised signed-out access gates. Interactive Google sign-in as the requested administrator and real provider-account checks were not performed. KORONA/Cova checks were tested with documented-contract fixtures, not live merchant credentials. Payment capture, supported terminal execution, automatic POS-data ingestion and automatic sale-to-gram deductions remain separate work. POS/tipping and commission output remain previews; the existing POS is required for checkout.

The verified restore was local to SER8. Off-host recovery and primary-POS cutover acceptance remain separate verification. Preserve new audit and credential tables when rolling back compatible code; dropping them would discard subsequent business/setup records.
