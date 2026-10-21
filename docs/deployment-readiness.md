# Rupert deployment ready

Audit baseline: `458bd1c0045a24d0aee2bac1b664b36c96e57c9c` on `main`, October 20, 2026 (America/New_York).

[Persistent blueprint](https://github.com/techmore/rupert/issues/207) · [Deployment milestone](https://github.com/techmore/rupert/milestone/1)

## Required gates

- [Verify the release candidate, live revision and fresh recovery evidence](https://github.com/techmore/rupert/issues/202)
- [Bind bank statements to a specific ledger account before reconciliation](https://github.com/techmore/rupert/issues/203)
- [Decide and implement sales-to-ledger posting policy or disclose incomplete statements](https://github.com/techmore/rupert/issues/204)
- [Complete the bounded daily-use pilot and operator acceptance checklist](https://github.com/techmore/rupert/issues/205)
- [Define required checks and protect the release branch](https://github.com/techmore/rupert/issues/206)

## Evidence contract

GitHub tracks issues and features across sessions. Gate completion, exact-commit CI, deployed source identity, fresh recovery evidence and operator/customer acceptance are separate facts. Do not use a passing workflow or a merged pull request to declare production ready. Counts represent completed gates, not estimated engineering effort. Keep unverified gates open and record any explicit rollout scope decision.

The October 20 audit inspected source, existing reviews, issue/PR history, CI and repository protection settings. It did not access production, change business data, initiate network scans, validate credentials, or conduct new customer acceptance. main had no branch protection and no rulesets in the audit reads; the linked CI gate tracks the policy decision rather than silently changing it.

## Audit reconciliation

Audit #169 is retained. Its remaining work is statement/account mapping (M1/M7) and sales-to-ledger policy/completeness (M4), split into the gates above. Prior M2/M3/M5/M6/M8/M9/M10/M11 and the low rollup have merged fixes (#171, #173, #174, #175); do not recreate those findings from the original issue body. Active PRs #199 and #201 remain separate reviews.

The audited main passed PostgreSQL, SQLite, product-site and dependency/static CI. This is the historical October 20 multi-adapter result; current CI is SQLite-only. Independent product-site generation/link validation and all 12 browser-controller checks passed. Merchant acceptance, physical-stock validation and current live release/recovery were not reverified. The initial goal is a bounded operational pilot alongside the existing POS, per [day-to-day readiness](ops/day-to-day-readiness.md), not an implicit expansion to every ERP capability.
