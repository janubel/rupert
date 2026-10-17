# Operator audit trail deployment — October 17, 2026

[PR #99](https://github.com/techmore/rupert/pull/99) deployed application revision `5c585f12b2e411507ae0114cddc6c332bfb8e914` to SER8 at about 09:10 America/New_York, fast-forwarding the live checkout from `2e41033`. No migrations, gem changes, credential changes or provider writes. Findings are in the [operator audit](../audits/2026-10-17-operator-audit.md).

## Release
- Activity entries for database restore and backup download, secret export (including denied attempts) and import, Google sign-in credential and domain changes, Drive backup and disconnect, API token issue and revoke, location changes, and every reconciliation action (evidence, archive, review, withdrawal, close package, cash forecast, follow-ups). Details never include secret values.
- Retention: Activity entries kept 7 years (was 90 days), sign-in attempts 2 years (was 90 days).
- Activity page: group, text and date filters, paging, formula-safe CSV.

## Validation
- CI passed on SQLite and PostgreSQL for the exact commit; RuboCop clean; 131 related tests passed locally before the final view fix, and the audit-trail suite (8 tests) after it.
- Rehearsal on a consistent copy of the production database using the exact source: no audit-log rows would be pruned under the new policy, a probe entry was written and filtered on the copy only, and 98 legacy rows stored with subject type `NilClass` were identified (the page now hides it).
- Recovery points: private database backup `/var/backups/rupert/pre-operator-audit-20261017-090240` (integrity `ok`) and Incus snapshot `pre-operator-audit-retry-0906`. Rollback: `git checkout 2e41033` and a host-side `incus restart rupert`.
- After the host-side restart: web and jobs active, `NRestarts=0`, checkout clean at `5c585f1`, database integrity `ok`, `/up` and `/login` returned 200 on `pos.rupertpos.com`, signed-out `/activity` redirected to login.

## Incident note
`incus snapshot create` freezes the container for the duration of the copy (storage pool type `dir`). The retry at 09:06 froze production for about two minutes; the first attempt in this window timed out without producing a snapshot. Plan snapshots for a quiet period, or use the database backup alone, until the pool type changes.
