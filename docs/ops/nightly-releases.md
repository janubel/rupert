# Nightly releases and build totals

This workflow uses the repository's
[development and deployment workflow](../development-and-deployment-workflow.md).
Publishing a nightly prerelease does not itself install it on SER8; the live
revision depends on the updater mode and must be verified separately.

The nightly Codex task runs at 02:00 America/New_York. It reviews integrated
changes, investigates regressions, prepares tested fixes and release notes, and
publishes a `nightly-YYYY-MM-DD-<short SHA>` **prerelease** only after the exact
integrated source passes checks. Stable `v*` releases and `VERSION` are unchanged.
No empty nightly is required when the source has not changed.

## Build metadata

`assets:precompile` generates `web/config/release_metadata.json` from full Git
history. The generated file is ignored by Git. The running process reads it once
alongside its build identity and rejects a manifest for another revision. The
header therefore measures the serving source, even when a newer release exists.
There are no Git scans, external requests or business-database reads per page.
Missing/stale/invalid metadata displays “Change totals unavailable”. Shallow
source builds fail instead of claiming incomplete cumulative totals.

Generate a reproducible snapshot and notes with Ruby, from the repository root:

```sh
ruby bin/build-release-metadata --revision HEAD \
  --output /tmp/release-metadata.json --notes /tmp/nightly-notes.md
```

An optional `--base <full SHA>` selects an explicit nightly baseline. Otherwise
the baseline is the previous reachable nightly tag, excluding tags at the source
revision itself. On the first run it is the first-parent commit before the source
commit time minus 24 hours. The manifest records the exact base, source, as-of
time and counting rules. A retry of the same release must reuse its original
baseline. Notes include all non-merge commits since the latest reachable stable
release, independently of the nightly measurement window.

Patch totals are distinct non-merge commits changing selected source paths.
Line additions/deletions are per-commit text churn in that same scope, rather
than a net tree diff. Source size counts current physical source lines, including
tests, blanks and comments. Dependencies, lockfiles, generated output, docs and
legacy are excluded. Historical Rust source contributes to historical patch
and churn totals even though that component was removed. Count rules are in
`web/lib/nightly_release.rb`; retain them with published metadata.

Confirmed fixes come from reviewed entries in
`web/config/confirmed_release_fixes.json`. Each distinct bug has an ID, full fix
commit and explanation supported by a reviewed diff/regression test. Multiple
commits for one bug must share one registry entry. Only reachable fix commits
count. This registry is incomplete: its tracked fixes must never be presented
as the total number of bugs ever fixed or as the number of open bugs.

Git-free images must include a manifest generated for their exact source SHA.
Before a Docker build, run `ruby bin/build-release-metadata` in a clean checkout
and pass that same full SHA as `RUPERT_BUILD_SHA`. The customer image builder
generates metadata before removing `.git`. Images without it still boot with an
honest unavailable state.

## Publish and verify

1. Preserve ongoing work, branch from current `origin/main`, validate the source,
   header and counting tests, and land the focused PR after required checks pass.
2. Verify the **integrated SHA's** SQLite CI, product-site, security and applicable
   mobile checks. Generate metadata/notes at that SHA; keep the baseline fixed on
   retries. Add a concise reviewed highlights/known-issues section and actual
   validation links to the notes. Do not imply that commit subjects alone prove
   feature acceptance.
3. Publish a unique `nightly-*` tag and GitHub prerelease targeting that exact SHA,
   attach `release-metadata.json`, and mark it **not latest stable**. Do not use
   `v*` tags or dispatch the stable `Release` workflow for a nightly. Do not claim
   binary artifacts were built when only source checks/assets were built.
4. Record the release, SHAs, baseline, checks and unresolved gates in task memory.
   Advance the successful-release checkpoint only after publication succeeds.

Production behavior follows the installed updater and operator-selected mode;
`deploy/ser8/README.md` documents automatic versus requested installs. Merging a
green commit can make it eligible for that existing updater. This task does not
invoke a production install or change updater mode. Check `/up`'s
`X-Rupert-Build` and the rendered header before saying the live app is updated.
A published prerelease is not merchant, payment, device or operator acceptance.
