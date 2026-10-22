# Integration maintenance audit — October 21, 2026

## Scope and evidence

Audited the verified `origin/main` source in the Rupert repository. GitHub
reports `origin/HEAD -> origin/main`; `docs/BRANCHING.md` names `main` as the
production Rails source and says deploys are separate from merges. The starting
checkout was the older `rust-core` archive branch, clean of tracked changes;
existing untracked `.worktrees/` and `core/` content was preserved. Work began
on `codex/integration-audit-20261021` from `origin/main`.

The latest repository-recorded production read is the October 20 read-only
inspection at runtime revision `bbf367de` in
`docs/ops/time-records-audit-2026-10-20.md`; earlier October 17 receipts record
`96da4700` and `b5e2a40`. Those are dated observations, not a fresh check of
SER8 today. Current `main` and this proposed patch are not established as built
or deployed. Rust source was removed from current `main` in PR #176 on October
19. The archive branch and October 17–18 separate `rupert-core` build/deployment
receipts are historical evidence, not proof that the separate service remains
current or accepted. Mobile remains source with CI/diagnostic JS export
evidence; `mobile/README.md` says signing, store submission and real-device
acceptance are still deferred. None of those establishes current release
acceptance.

Open PR review found no overlap with the selected Square read path. PR #283
(`claude/ledger-sales-posting`) changes accounting posting and refund reporting;
PR #269 (`feature/zelle-reporting`) adds manual Zelle evidence. Both target
`main` and need their own review/acceptance. Mobile PR #300 restores the
supported Expo SDK 58 dependency set; PR #238 updates React in that same mobile
dependency area. These open PRs do not establish a built, signed or accepted
mobile release.

## Ranked findings

1. **Confirmed source gap — Square inventory count pagination.** In current
   `main`,
   `SquareClient.inventory_counts` chunks catalog IDs but processes only the
   first response from each `POST /v2/inventory/counts/batch-retrieve`. The
   response cursor is ignored. Square documents that this endpoint returns
   paginated results, exposes a response cursor and accepts that cursor on the
   next request. A catalog/location request with more returned counts than one
   page can therefore produce an incomplete local mirror. `SquareSyncer` reads
   the catalog, all counts and orders before it writes mirrored locations or
   levels, so raising on an incomplete later page keeps the prior snapshot.
   The focused change follows each cursor, preserves each location's own count,
   and rejects a repeated cursor rather than looping forever.
2. **Version review due, no version-specific incompatibility established.**
   Rails pins Shopify Admin GraphQL and app webhooks to `2026-07` in
   `web/config/shopify_api_version.rb` and `shopify.app.toml`; the July release
   is stable and supported, while Shopify's current release schedule lists
   `2026-10` as latest stable. Keep the existing pin for this narrow fix; review
   the `2026-10` release notes and run a separately scoped compatibility change
   before upgrading. The configured Square REST header is `2026-07-15`; the
   vendor's current docs show `2026-09-16`. Square version selection applies to
   all APIs, so do not change it incidentally with this pagination repair.
3. **Operational state remains unverified.** The current day-to-day readiness
   plan says Square is disabled in the current retail operating model and
   C-Trax is the physical-count reference. This code fix improves the dormant
   Square mirror path; it does not establish active Square credentials,
   account-level location coverage, correct source quantities, a production
   deployment or operator acceptance. Shopify and Square quantities remain
   separate pools; this change never combines or equalizes them.

## Focused source change

Old behavior: one page per batch of up to 100 Square catalog variation IDs;
remaining pages were silently omitted.

New behavior: replay the exact same read filters with each returned cursor until
Square returns no cursor. Aggregate the total only for the existing summary;
retain each count under its exact location and variation. If a later page
fails, propagate the failure before `SquareSyncer` writes, leaving the previous
local snapshot available. No outbound platform mutation is introduced.

Synthetic fixtures cover a two-page response with stock split across two
independent locations, a replayed cursor, and a failure on page two after page
one succeeded. The repeated-cursor case fails closed rather than looping; the
failure case verifies the read raises after the configured transient retries,
so callers cannot mistake a partial response for a successful snapshot.

Verification: `bin/rails test test/services/square_client_test.rb` passed on
Ruby 4.0.6 against an isolated, temporary SQLite test database (7 tests, 21
assertions). `git diff --check` passed. Targeted RuboCop was also run; it reports
existing class/method length, complexity, and formatting offenses across the
Square client and its pre-existing tests, but reports no offense in the new
pagination helpers or added fixture lines. This is a focused source/test check,
not full CI.

## Other inspected surfaces and limits

- Shopify `2026-07` catalog, locations, inventory levels, order connections and
  order line-item continuation have cursor-following code and synthetic page
  tests. The current request did not make any live reads.
- Shopify source quantities include `available`, `on_hand` and `committed`;
  the older general sync still has a nonnegative availability mirror path. The
  current operating guide distinguishes signed native on-hand worksheet
  snapshots from the mirror and says missing/stale evidence remains unavailable.
  Do not treat local mirror success as physical count acceptance.
- Square read retries handle `429`, `5xx` and connection errors. The inspected
  Square inventory path is REST and has no Rust consumer in current `main`.
- The repository's manual SwipeSimple CSV/report importers and C-Trax, payment
  and reconciliation workflows have explicit coverage/unknown-state limits in
  current docs. No webhook registration, scope edit, payment, terminal,
  source sync, live source read or production data change was performed.

## Sources

- Square Batch Retrieve Inventory Counts API reference:
  https://developer.squareup.com/reference/square/inventory-api/batch-retrieve-inventory-counts
- Square API versioning overview:
  https://developer.squareup.com/docs/build-basics/versioning-overview
- Square `2026-07-15` release notes:
  https://developer.squareup.com/docs/changelog/connect-logs/2026-07-15
- Shopify API versioning and support schedule:
  https://shopify.dev/docs/api/usage/versioning
- Shopify `2026-07` release notes:
  https://shopify.dev/changelog/release-notes/2026-07
- Shopify inventory quantities documentation (searched through the AI Toolkit
  for configured Admin API version `2026-07`):
  https://shopify.dev/docs/apps/build/orders-fulfillment/inventory-management-apps/manage-quantities-states

## Next iteration

Review Shopify `2026-10` and Square `2026-09-16` release notes against their
configured pins, then gather a current owner-approved account/location sample
before claiming live Square or Shopify coverage. Use only read-only source
evidence; physical inventory and payment acceptance remain operator gates.
