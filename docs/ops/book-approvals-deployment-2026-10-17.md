# Approve books deployment — October 17, 2026

[PR #100](https://github.com/techmore/rupert/pull/100) deployed application revision `bb8bf37de9ed70347ee797624be9f79589a7f190` to SER8 at about 09:32 America/New_York, fast-forwarding the live checkout from `5c585f1`. One additive migration (`20261017150000`, new table `book_approvals`); no existing table, gem, credential or provider changed. See the [compliance audit](../audits/2026-10-17-compliance-retention-accounting-audit.md) and the [operator guide](book-approvals.md).

## Release
Approve books (`/approve_books`) with a hash-chained approval ledger; evidence-only report fingerprint (reviews no longer go stale on every sync); logging of every export and download; period-aware, field-level logging of expense and vendor-payment edits; Books check items for the approval ledger, recent approvals and off-host backup.

## Validation
- CI passed on SQLite and PostgreSQL for the exact commit; full local suite 1,504 tests, zero failures; RuboCop clean.
- Rehearsal on a consistent copy of the production database using the exact source: migrate, rollback to `20261017120000`, re-migrate (integrity `ok`), and two approvals recorded on real period data with the chain verifying and the approval state moving from pending to approved. Probe rows existed only on the copy, which was deleted.
- Recovery point: private database backup `/var/backups/rupert/pre-book-approvals-20261017-093137` (integrity `ok`, no foreign-key violations). No Incus snapshot was taken, by decision, because a snapshot freezes the container for the duration of the copy. Rollback: `git checkout 5c585f1`, a host-side `incus restart rupert`; the unused additive table can stay.
- After the host-side restart: web and jobs active, `NRestarts=0`, checkout clean at `bb8bf37`, migration version `20261017150000`, database integrity `ok`, `book_approvals` empty, `/up` and `/login` returned 200 on `pos.rupertpos.com`, signed-out `/approve_books` redirected to login. No approvals or test records were created in production.

## Not verified
The page has not been viewed in a browser against live data; the first real approval will be the owner's.
