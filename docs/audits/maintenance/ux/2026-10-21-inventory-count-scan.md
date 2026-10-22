# Inventory scan target clarity — October 21, 2026

## Scope and source status

Audited the keyboard-wedge scanner count journey: create/open a draft, identify
its source and location, enter a code, save a count, recover from an uncertain
response, and review the stored worksheet. The product catalog places count
worksheets in the current inventory-execution phase. The existing [mobile
learning audit](2026-10-21-mobile-learning.md) found no source defect in its
chosen journey, so this pass selected a different operator task.

`origin/HEAD` resolves to `main` at `3fd1d0ad8f940bc18e49da4cf536e24bb781fa71`.
`docs/BRANCHING.md` names `main` as the Rails production source branch and says
deployment to SER8 is a separate manual release. The local `rust-core` checkout
was stale and its upstream branch is gone; its preserved remote counterpart is
`archive/rust-core`. The Rails `web/` application is the documented production
implementation. The latest explicit SER8 receipts reviewed here are the
October 17 combined release (`96da470…`) and timesheet review (`b5e2a40…`);
they do not establish which revision is running on October 21. No Rust runtime
integration, current build, deployment, or operator acceptance was found in
the current main documentation. Treat that Rust work as archived source, not a
production component.

The employee app in `mobile/` is Expo/React Native source. CI can validate and
export JavaScript/assets; those exports are not signed installable binaries.
The open [PR #300](https://github.com/techmore/rupert/pull/300) targets `main`
and its mobile validation and CI checks were green at review time. The mobile
README still requires owner-selected EAS/store accounts, signed builds, and
real-device acceptance; no store submission or device acceptance is established
by this audit. Other open work reviewed included PRs #295 (logging), #299
(upload quotas), #301 (local-model research), #283 (ledger sales), #269
(Zelle), #243 (Pagy), #238 (React), and #228 (Bookkeeping navigation). No open
inventory-count UX PR was found. The existing UX and Shopify pagination
worktrees in the repository were clean; this change is isolated from them.

## Findings

1. **P2 — Scanner target hid the platform.** The scan page displayed the
   selected location name but not its source. A store name alone can be
   ambiguous when operators compare independent source/location pools. The
   prepared count flow already labels the selection as `Platform · Location`,
   but that context disappeared after opening the scanner.
2. **P3 — The first scan has no empty-state copy.** Before the first confirmed
   save, the “Saved quantities” heading is followed by a blank list. The live
   status region exists, and the instructions say to wait for “Saved”, but a
   short first-scan prompt would make the initial state clearer. Deferred to a
   separate iteration to keep this change focused.

Existing source behavior inspected: scan writes are local to a draft worksheet;
the exact stored code is resolved before recording; request tokens make a
same-entry retry idempotent; failed or unconfirmed requests retain the entry
and token; a successful response updates the displayed quantities; closed
worksheets cannot be scanned. Inventory access requires both read and write
permissions, and counts are tenant-scoped. Approval remains an audit record.
No inventory, SKU, payment, or source-platform mutation was performed.

## Change and validation

Changed the scanner header to display `Target: Platform · Location`, or
`Target: no source/location selected` when the draft has no selected location.
Added render assertions for both states. No count rules, source matching,
permissions, or save behavior changed.

- Focused scanner integration suite on an isolated SQLite test database: **18
  tests, 129 assertions, 0 failures/errors/skips**.
- Tailwind CSS build succeeded.
- Product site consistency check passed (68 features, 18 competitors, 38
  comparison rows).
- Documentation links passed across 21 pages.
- JavaScript tests passed (45 tests).
- `git diff --check` passed before report creation; the staged diff was checked
  again before commit.

The Rails render assertions exercise the changed UI with synthetic fixtures;
there was no separate browser screenshot, physical scanner, production page, or
operator/device acceptance. No live service credentials or external reads were
used. These results do not establish current SER8 deployment, merchant setup,
physical stock accuracy, or mobile distribution.

## Next iteration

Add a concise first-scan empty state and exercise the scan page at narrow
viewport widths with keyboard focus and a simulated lost-response retry. Keep
the target's source/location identity visible and use synthetic data only.
