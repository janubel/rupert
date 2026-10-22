# Maintenance security review — 2026-10-21

Review scope: current Rails `main`, the independently versioned Expo employee client, and the archived Rust core branch. This is a source and automated-check review, not a penetration test, compliance assessment, or production acceptance. No production host, store, payment provider, database, or customer/employee record was accessed or changed.

## Branch and delivery state

- GitHub's default branch is `main` (`origin/HEAD`), at `3fd1d0ad` during this review. `main` contains the Rails app in `web/` and is the current source line. The checked-out historical `rust-core` line is archived as `origin/archive/rust-core` at `a5dd29a1`; its former tracking ref is gone. Do not merge that branch wholesale into `main`.
- The repository's 2026-10-20 production readiness record identifies production at `4e45c061` (last recorded 2026-10-19) and says it was 79 commits behind `main` at that time. The documentation calls `main` the production source line, but this review did not independently inspect the host or verify a deployment. Source, build, deployment, and merchant/operator acceptance are separate states.
- Rust archive history records hardened build `27fcd16` deployed to `rupert-core` and verified, then later backup/restore and unattended-run receipts through `a5dd29a1`. Those are historical documentation receipts only; no present-day host state was checked. The separate public deployment/runbook docs describe an uncompleted owner-facing public exposure process. Rust is retired from current product work.
- `mobile/` is a separate Expo employee client. It is source code, not evidence of a signed or store-distributed release. Open PR #300 addresses the current Expo SDK/toolchain compatibility; PR #238 separately updates React. These were left to their active PRs.
- Other relevant active work was kept separate: PR #299 covers serialized upload quota enforcement; #243 is a major Pagy update; #295 covers production logging. No overlapping change was made.

## Findings

### Confirmed and fixed — MCP Origin validation (moderate web boundary issue)

`McpController#allowed_origin?` previously allowed any parsed URI whose hostname matched the request host. That accepted a different scheme or port, and URIs with user-info or an unrelated path, which could weaken the browser-origin boundary for bearer-authenticated MCP requests. The MCP transport security requirements call for validating `Origin` and rejecting invalid origins with 403 ([official transport spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)).

The source now accepts only a same-origin tuple (scheme, host, port), or a tuple explicitly listed in `MCP_ALLOWED_ORIGINS`. It rejects user-info, non-root paths, queries, fragments, malformed values, and non-HTTP(S) schemes. Requests without an Origin header keep the existing behavior for non-browser clients. A synthetic integration regression covers same-origin acceptance; scheme, port, user-info, and path mismatch rejection; and explicit allowlisting.

This is a source fix on the review branch only. It has not been deployed or accepted by an operator.

### Reviewed follow-ups — not confirmed exploitable

- A local Brakeman run against the current Rails source surfaced new warnings for `permit!` in bank-statement and QuickBooks mapping flows, plus dynamic `send` in project task/transition flows. The bank-statement pattern is already documented and constrained; the QuickBooks mapping path extracts a fixed set of fields from tenant-scoped mapping rows and validates the decision/target; transition events are selected from literal allowlists. I found no verified exploit path in these reviewed uses. The committed Brakeman baseline and current CI pass; do not silence or expand the baseline without a separate evidence-backed review.
- Rails CSP still permits inline script/style in the current configuration, an existing documented hardening follow-up. No safe narrow replacement was established in this audit.
- `npm audit` on `main` reports 15 high entries in the mobile dependency graph, including the documented narrowly scoped source backports for `braces` and `node-forge` and a UUID advisory. The project's mobile security note documents the backports; the raw scanner remains noisy. Its suggested broad fix would downgrade the Expo/RN stack and is not a safe remedy. Expo SDK 58's published compatibility matrix specifies React 19.3.0 and React Native 0.88 ([Expo SDK 58](https://docs.expo.dev/versions/v58.0.0/)); coordinate remaining dependency work with PR #300 and the mobile owner. No mobile package changes were made.
- The Rust archive pins dependencies in `core/Cargo.lock`; its test suite passes below. No `cargo-audit` binary was available in this environment, so no independent RustSec advisory database scan is claimed. The archive is not the current production source branch.

## Checks performed

- Current main GitHub Security workflow on `3fd1d0ad`: success. The dependency audit and Brakeman baseline steps both completed successfully.
- MCP-focused integration tests: 32 tests, 523 assertions, zero failures/errors.
- Tenant, employee-role, and checkout/payment replay test set: 54 tests, 454 assertions, zero failures/errors/skips. All fixtures were synthetic/local.
- RuboCop on the changed Rails controller and integration test: two files inspected, no offenses.
- Archived Rust core at `a5dd29a1`: `cargo test --locked`, five unit tests passed. This verifies only the archived source on this host/toolchain.
- The source regression failed against the pre-fix controller (one test, three assertions, failure) and passed after the fix (one test, seven assertions).

## Limits and next iteration

No live Shopify, Square, payment, production data, schema, route, authentication, secret, or mobile-signing operation was performed. No deploy, merchant acceptance, external service acceptance, or full penetration test is claimed. The mobile dependency advisory entries need reconciliation with upstream package metadata and the active SDK PR; the Rust archive needs a current RustSec scan only if that retired line is considered for reuse. The next maintenance iteration should re-check the production revision and deployed status from an authorized read-only host receipt, then reconcile the mobile advisory scan after PR #300 lands.
