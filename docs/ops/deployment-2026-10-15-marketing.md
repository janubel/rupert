# SER8 community marketing deployment — October 15, 2026

Verified approximately 10:44 PM America/New_York (02:44 UTC October 16).

## Release and behavior

Feature implementation: [PR #61](https://github.com/techmore/rupert/pull/61), commit `3615bcdb625c0c5387884caef474a79338e0bcdf`. SER8 application release: [`1cecc3458e97adfae2b3434ef6da9b7e4a011cdf`](https://github.com/techmore/rupert/commit/1cecc3458e97adfae2b3434ef6da9b7e4a011cdf) on `deploy/marketing-thread-review`.

The deployment branch preserves the previously running `21966e012a4b1ea906452f905d8845a9c3f5bd2f` release, including the existing source cards, native payment reporting, SwipeSimple pulls and money-reconciliation workflows. It adds phase-one community marketing. The feature PR remains scoped to marketing for integration into main; the deployment branch records the additional live-release ancestry.

Marketing is enabled for the existing Herbal Healers workspace; other workspaces remain disabled by default. Existing administrators have the default Marketing permissions; explicit role/person overrides remain authoritative. Open [Marketing](https://rupert.stoverparc.org/marketing) after signing in and follow the [operator guide](community-marketing.md).

The release provides topic-search links, manual thread intake/triage, existing group-code records with dated merchant evidence, exact reply revisions and review history, eligible approved copy, and manual publication/removal records. No sources were scraped, messages posted, merchant discount codes created/changed, or inventory mutated during deployment. Influencer CMS, automated discovery and attribution remain later phases.

## Recovery and migration

A consistent SQLite backup, private environment/service copies, previous assets and before-promotion database copy are retained privately under `/var/backups/rupert/pre-marketing-1cecc34`. Incus snapshot `pre-marketing-1cecc34` was taken before promotion. These are local recovery points, not an off-host recovery verification.

Migration `20261017010000` was applied, rolled back and reapplied on a production copy. All 112 prior tables retained their row counts; six empty marketing tables were added. Production-mode eager loading and assets compiled on the staged release. A rollback-only smoke verified queue/forms/review/copy/publication rendering and workflow without retaining test records.

Live promotion used the deployment lock, an exact clean-release check and zero-claimed-jobs check. Dedicated web/jobs cgroups were verified by systemd unit, configured working directory, service user and member process ownership. Ordinary signals remained denied on this host, so the established service-cgroup activation procedure was used without changing AppArmor or container privileges. Services were briefly stopped, a fresh quiesced database backup was taken, and migration preserved all prior-table counts before the intentional workspace feature-flag change. Private configuration and service definitions remained unchanged.

Compatible code rollback should preserve the new tables and subsequent marketing history. Do not replace the active database with the frozen PostgreSQL copy or discard subsequent business records.

## Verification

| Check | Result |
| --- | --- |
| Feature CI | SQLite and PostgreSQL passed |
| Exact deployment candidate CI | SQLite: 987 tests / 7,137 assertions; PostgreSQL: 987 tests / 7,122 assertions, two SQLite-only skips; zero failures/errors |
| RuboCop / product docs | 517 files without offenses; 65-feature catalog and doc-link checks passed |
| Local integration regression before the final money-review ancestry merge | 976 tests / 7,057 assertions; zero failures/errors |
| Production checkout | Exact deployed commit, clean |
| Web / jobs | Active; restart counters zero after activation |
| Production database | Integrity `ok`, zero foreign-key violations; maximum migration `20261017010000` |
| Proxy-aware `/up`, `/login` | HTTP 200 |
| Signed-out `/marketing`, `/marketing/threads/new` | HTTP 302 to login |
| Public HTTPS `/up`, `/marketing` | HTTP 200 / 302 |
| Live rollback-only smoke | Queue and forms render; reply submit/approve/copy/publication/removal succeed; source text escaped; no persisted smoke rows |

The live smoke used an existing authorized administrator's tenant context for rendering and a database transaction rolled back in full. It did not perform an interactive Google sign-in or publish anything to a social platform. No real group, offer or campaign was seeded; operators must enter the pilot's actual rules, merchant evidence and discussions.
