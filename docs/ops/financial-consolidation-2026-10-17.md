# Financial consolidation — October 17, 2026

Original review candidate: [PR #107](https://github.com/techmore/rupert/pull/107), branch `codex/financial-consolidation`, based on `fix/operations-workspace-ux` at `2a4cae6`. This document records its source consolidation, not an audit of live balances. The later [combined-release deployment and recovery receipt](combined-release-recovery-2026-10-17.md) records production activation at `96da470` and completed migration, page and recovery verification.

## Included branches

| Branch | Scope |
| --- | --- |
| `main` at `19d0c2c` | Customer navigation and repository maintenance |
| `feature/books-desk` at `b54a1a4` | Books desk, period-end checklists and period locks (#103) |
| `fix/money-close-correctness` at `dc60e2e` | Informational controls, amount parsing, business-day defaults (#104) |
| `ux/cash-forecast-entry` at `2f8dee5` | Prefill, explicit blank-as-zero confirmation, spreadsheet entry (#105) |
| `perf/portal-observations` at `de370be` | Indexed encrypted portal observations (#106) |
| `claude/authorize-net-native` at `106fcf0` | Payment credential setup, wallet checkout and gateway client methods |

Existing branches and PRs remain available. #107 targets its immediate operations base; #94 is the parent change toward main. Do not independently merge overlapping candidates without checking ancestry and the resulting combined diff.

## Integration repairs

- Preserve both Customers and Books desk dashboard entries.
- Preserve forecast retention Activity logging together with exact blank confirmation and prefill provenance.
- Preserve newer reporting credential labels and provider-specific login limits alongside the public client key.
- Include both the period-lock and portal-observation tables, indexes and foreign keys in both schemas. The SQLite schema was dumped after running the missing observation migration; the PostgreSQL schema retains its adapter-specific types.
- Use the same actionable-difference rules for close blockers, the default comparison list and its count. Informational controls remain available under All metrics and in exports.
- Separate payment and refund archive totals by source and currency.
- Never combine incomplete saved payment credentials with legacy settings. An incomplete saved connection remains unconfigured.

## Validation and promotion

Final local validation: 1,573 Rails tests / 12,295 assertions, zero failures/errors/skips; 780 Ruby files without lint offenses; six JavaScript suites; product-site, documentation-link and diff-whitespace checks passed. PostgreSQL and SQLite GitHub CI results are recorded in the PR. Local checks use Ruby 4.0.6, synthetic databases, test keys, `LANG=en_US.UTF-8` and isolated SQLite paths. The full suite requires permission for worker sockets and system metrics on this host. All gateway requests in tests are mocked.

At the original source-review checkpoint, SER8 SSH timed out and the latest documented application revision was `9b6c35e`; that review performed no deployment. The later combined-release pass verified live source, preserved the four newer controller changes, rehearsed migration and recovery on an isolated current copy, and deployed clean revision `96da470` at 14:03 America/New_York. See the [deployment receipt](combined-release-recovery-2026-10-17.md) for completed migration, page and encrypted off-host recovery results. No live charge, refund, bank decision, approval, inventory write or credential update was used as a release probe.

For subsequent deployments, verify the current live revision and any uncommitted work under the deployment lock, incorporate intervening changes and rerun combined checks. Back up and rehearse additive migrations against an isolated current copy. Portal observation backfill requires the existing production encryption keys. Do not overwrite concurrent live work or restore an older database to revert source code.

Informational-control status changes alter daily report digests for days containing tips, fees or deposits; affected days require another review and retained packages must be checked against the new digest. Payment/refund period snapshots now include source and currency, so existing period-lock fingerprints may change and require explicit inspection rather than silently rewriting historical lock events. Wallet and live gateway readiness remain merchant-specific and unverified.
