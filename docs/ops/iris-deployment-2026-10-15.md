# IRIS reporting deployment — October 15, 2026

SER8 application code now runs `9b23fcec4d93e4bca614d76d10a0747d6bb699a7` on the existing `/opt/rupert` checkout. The release branch is `codex/ser8-iris-reporting`. It preserves the C-Trax, Authorize.net, Google-login and SwipeSimple changes already present in production, including the latest gateway-key safety guidance. The initial revision guard stopped preparation when another deployment advanced SER8; the updated release incorporated that revision before promotion.

## Recovery and verification

- Private consistent SQLite/configuration/service backups: `/var/backups/rupert/pre-iris-20261015-9b23fce`.
- Incus recovery snapshot: `pre-iris-20261015-9b23fce`.
- Migration, rollback and reapplication rehearsed on a private database copy. All 109 existing table counts were preserved. Integrity and foreign-key checks passed.
- Live additive migration: `20261016021000` (`CreateIrisReports`). Existing C-Trax and SwipeSimple migration identities were also checked.
- Activation used host-side `incus restart rupert`. Web and jobs are active; public HTTPS `/up` returns 200; the production checkout is clean.
- Combined SQLite test suite: 922 tests, 6,613 assertions, zero failures/errors/skips. Configured RuboCop passed across 476 files; generated-site and documentation links passed.
- The deployed release passed GitHub's PostgreSQL and SQLite CI: [release workflow](https://github.com/techmore/rupert/actions/runs/38835498550). The original IRIS source PR also passed both adapters.

## First real data and remaining access

Six encrypted monthly summary snapshots were imported from the authenticated portal's visible Sales Health and Transaction Health tables. They are explicitly private CSV transcriptions of visible data, **not native downloaded exports**. Source URLs, merchant context, capture date and private CSV files remain outside public Git. Import verification confirmed the expected snapshot count and unchanged canonical sales. The application audit log identifies the transcription source.

The portal's CSV export still did not deliver a downloadable file in the in-app browser. Native file compatibility remains unverified. No merchant password, cookie or hidden browser token was used as backend API authentication. No financial transactions, merchant configuration, inventory or account permissions were changed.

No approved NAB/IRIS API token is available. Automatic API reporting remains disabled and unverified; the deployed scheduler becomes usable after approved credentials and opt-in are configured. Existing owner-password recovery-file authentication could not be verified, so no authentication setting or credential was changed. This does not affect the verified report-storage import or deployed service health.

See [IRIS reporting runbook](iris-reporting.md) for setup, source limits, the prepared NAB access request, CSV formats and ongoing operation.
