# Main / SER8 repository reconciliation — October 16, 2026

The initial baseline was the clean SER8 dog-favicon release `2617ab03a11ebeb48327643160f4ec86f83e6024`. During review, SER8 advanced to dog-header release `0cd3be6031f5ebe96ba0679bc8f02ab4691a7d3b`; its history and exact application files are included too. SER8 then advanced to `e9a495987cc01224e0488b2317c0f043dbc845f2` (C-Trax dashboard and workspace UX, PR #90), which is also included as a merge parent. The observed worktree removed only the Bundler 4.0.16 checksum entry from `web/Gemfile.lock`; the original patch is preserved and this non-version change is incorporated so the checkout can become clean without discarding it. The previous main tip is `d63b99e8e294c9d6acbe07e56beab48079df9c3a`. Both original histories remain parents of the reconciliation.

Application and mobile application sources match the observed running tree. CI-only SDK compatibility checks are made reproducible against the installed Expo SDK manifest, while security auditing remains online; no mobile dependency versions are changed. Main-only NMI research, transaction-history operations and unique deployment/investigation documents are retained as documentation. Historical investigation notes are explicitly identified. This does not activate paused provider access, change credentials, run migrations or restart production services.

Four main-only employee fixes (`b888811`, `0f226fe`, `30709bc`, `6ff477b`) are patch-equivalent to commits already in the running history. Running employee permissions, current mobile security backports and dog icons take precedence over older overlapping versions.

Before cleanup, every fetched ref and all 31 open PR head/base identities were preserved in a verified Git bundle and inventory in the existing owner-verified private backup repository. No source branches are deleted. Original heads remain available for inspecting earlier work; a PR closed as superseded is not a claim that every historical line remains the current implementation.

## PR disposition

| PR | Original head | Disposition |
| --- | --- | --- |
| [#90](https://github.com/techmore/rupert/pull/90) | `e9a495987cc0` | Dashboard work deployed during reconciliation; include its full history and resolve after main consolidation. |
| [#89](https://github.com/techmore/rupert/pull/89) | `1b2cdf10bb7b` | Historical-record operations guide retained; merge its original history. |
| [#88](https://github.com/techmore/rupert/pull/88) | `15aa91cab546` | Included in running release ancestry; resolve after main consolidation. |
| [#87](https://github.com/techmore/rupert/pull/87) | `711793b6f132` | Included in running release ancestry; resolve after main consolidation. |
| [#86](https://github.com/techmore/rupert/pull/86) | `818349fc864b` | Included in running release ancestry; resolve after main consolidation. |
| [#85](https://github.com/techmore/rupert/pull/85) | `ff5f61e933f5` | Included in running release ancestry; resolve after main consolidation. |
| [#84](https://github.com/techmore/rupert/pull/84) | `301c854424c2` | Included in running release ancestry; resolve after main consolidation. |
| [#82](https://github.com/techmore/rupert/pull/82) | `fe291dbb1cab` | Stock feature files match running release; only an unrelated older role-help string differs. |
| [#79](https://github.com/techmore/rupert/pull/79) | `340275b6bfef` | Included in running release ancestry; resolve after main consolidation. |
| [#78](https://github.com/techmore/rupert/pull/78) | `e92feac8f1ed` | Distinct undeployed read-access diagnostics; retain as draft against reconciled main. |
| [#77](https://github.com/techmore/rupert/pull/77) | `ce3d1f19c7ba` | Included in running release ancestry; resolve after main consolidation. |
| [#76](https://github.com/techmore/rupert/pull/76) | `2d1e4b0f20a4` | Included in running release ancestry; resolve after main consolidation. |
| [#75](https://github.com/techmore/rupert/pull/75) | `f9eeed4c4475` | Discount feature is deployed; retain deployment receipt and newer shared app/security files. Provider permission remains separate. |
| [#73](https://github.com/techmore/rupert/pull/73) | `3d927fe8fbea` | Included in running release ancestry; resolve after main consolidation. |
| [#72](https://github.com/techmore/rupert/pull/72) | `b0764a9ef925` | Included in running release ancestry; resolve after main consolidation. |
| [#71](https://github.com/techmore/rupert/pull/71) | `dfa7c20f8055` | CMS is deployed; keep later Shopify-offer guards and referral handling from the running release. |
| [#69](https://github.com/techmore/rupert/pull/69) | `66ceb98bc710` | API investigation and evidence JSON retained; reporting enablement stays paused. |
| [#67](https://github.com/techmore/rupert/pull/67) | `ecc427a0027a` | Included in running release ancestry; resolve after main consolidation. |
| [#63](https://github.com/techmore/rupert/pull/63) | `fe32f223af3f` | Unique live-commission deployment receipt retained; no new provider activation. |
| [#62](https://github.com/techmore/rupert/pull/62) | `9402cc3afc4b` | Close workflow is deployed; retain its final receipt/help notes and the newer live favicon. |
| [#61](https://github.com/techmore/rupert/pull/61) | `ff2da09f3930` | Community review is deployed; keep later separation of community/influencer offers and retain its receipt. |
| [#56](https://github.com/techmore/rupert/pull/56) | `c3000f5577c3` | Historical implementation plan retained; unimplemented marketing phases remain tracked in issue #54. |
| [#52](https://github.com/techmore/rupert/pull/52) | `d8dc52201aa8` | Earlier connector/reporting iteration superseded by the deployed implementation; unique research/receipts retained and original branch preserved. |
| [#51](https://github.com/techmore/rupert/pull/51) | `a966487dac1d` | Included in running release ancestry; resolve after main consolidation. |
| [#50](https://github.com/techmore/rupert/pull/50) | `e2b5e81c5b3c` | Earlier connector/reporting iteration superseded by the deployed implementation; unique research/receipts retained and original branch preserved. |
| [#49](https://github.com/techmore/rupert/pull/49) | `c4504c2b8386` | Earlier connector/reporting iteration superseded by the deployed implementation; unique research/receipts retained and original branch preserved. |
| [#46](https://github.com/techmore/rupert/pull/46) | `ca681f4f51d4` | Included in running release ancestry; resolve after main consolidation. |
| [#45](https://github.com/techmore/rupert/pull/45) | `463a51bb1f19` | Earlier connector/reporting iteration superseded by the deployed implementation; unique research/receipts retained and original branch preserved. |
| [#44](https://github.com/techmore/rupert/pull/44) | `a249ae02f18a` | Earlier connector/reporting iteration superseded by the deployed implementation; unique research/receipts retained and original branch preserved. |
| [#43](https://github.com/techmore/rupert/pull/43) | `227261fcb0eb` | Earlier connector/reporting iteration superseded by the deployed implementation; unique research/receipts retained and original branch preserved. |
| [#42](https://github.com/techmore/rupert/pull/42) | `efce56328fae` | Included in running release ancestry; resolve after main consolidation. |
| [#17](https://github.com/techmore/rupert/pull/17) | `ad485150c53d` | Distinct undeployed host audit/backup script; retain as draft for revision. |

## Verification and publication

Check both database CI suites, product-site generation, local documentation links and mobile CI. Before reconciling the server checkout, recheck main and the exact running revision under `/var/lock/rupert-deploy.lock`. Require zero application/mobile/deployment differences from the observed live tree (including its captured checksum drift); review the CI-only workflow/validation tool separately. Fast-forward only. Do not run asset builds, migrations, service restarts or instance snapshots for this documentation/Git-history reconciliation.

If SER8 advances during review, incorporate and validate that newer release before publication; never replace it with this older checkpoint. Keep distinct undeployed PRs open as drafts, with their original branches intact.

The CI compatibility repair checks every installed declared package against its manifest range and SDK-controlled packages against the installed Expo compatibility map. A mismatch or missing dependency fails; self-checks cover both. Expo Doctor continues its other checks, and vulnerability auditing remains online. Dependency versions and application source are unchanged.
