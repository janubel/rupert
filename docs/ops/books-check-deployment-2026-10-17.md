# Books check deployment — October 17, 2026

[PR #98](https://github.com/techmore/rupert/pull/98) deployed application revision `2e41033c276ff85f8c07c8bdd63d69d74da75d93` to SER8 at about 00:17 America/New_York, fast-forwarding the live checkout from `9b6ba9bb108b72e4537bbaeebd78cae39bd4b5b5`. No migrations, gem changes, credential changes or provider writes. The findings behind the release are in the [finance audit](../audits/2026-10-16-finance-audit.md).

## Release
- Read-only **Books check** page (`/books_check`, Money navigation and Reports header) with CSV export.
- Financial report warns when refunded orders have no refund amount; Sales report shows orders without a location as "Unassigned".
- New-form default dates and two tests now use the business day (`Date.current`) rather than UTC `Date.today`.

## Validation
- CI passed on SQLite and PostgreSQL, product-site consistency and CLA for the exact release commit. RuboCop clean with `-c ./rubocop.yml`.
- Rehearsal: a consistent backup (integrity `ok`) was copied and Books check ran from the exact release source against the copy only, with production settings and no writes to the live database. It completed in 0.15 s with no fixes needed and five items to watch.
- Recovery points: Incus snapshot `pre-books-check-20261017-0020` (the first attempt, `pre-books-check-20261016-234835`, hung in the client and never produced a snapshot) and a private database backup in `/var/backups/rupert/pre-books-check-20261017-001628`. Rollback is `git checkout 9b6ba9b` plus a host-side `incus restart rupert`.
- Activation: assets precompiled, then host-side `incus restart rupert`. Web and jobs active, `NRestarts=0`, deployed checkout clean at `2e41033`, database integrity `ok`.
- Public checks on `pos.rupertpos.com`: `/up` and `/login` returned 200; signed-out `/books_check` redirected to login. No production records, reviews or sign-offs were created.

## Notes
- `rupertpos.com` (the bare domain) resolves to 216.40.34.41, not SER8 (71.162.207.117), and does not respond. The instance is served at `pos.rupertpos.com` and `rupert.stoverparc.org`.
- The first attempt to snapshot hung for about 25 minutes with no daemon operation; a retry succeeded. Worth investigating before the next deploy.
