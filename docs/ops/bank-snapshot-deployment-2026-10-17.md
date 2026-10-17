# Bank statements and business snapshot deployment — October 17, 2026

[PR #101](https://github.com/techmore/rupert/pull/101) and [PR #102](https://github.com/techmore/rupert/pull/102) deployed together as application revision `9b6c35e296cd3538f30426ab5521691d1366070a` to SER8 at about 10:03 America/New_York, fast-forwarding the live checkout from `bb8bf37`. One additive migration (`20261017180000`, new table `bank_statement_lines`); no existing table, gem, credential or provider changed. See [bank statements](bank-statements.md) and [business snapshot](business-snapshot.md).

## Release
- Finance → Bank statements: upload a bank CSV (original retained, descriptions encrypted), a person decides each withdrawal (expense, vendor payment or ignore), no line imported twice, who and when recorded, Activity log entries, approved-period warnings, Books check item for waiting lines.
- Money → Snapshot: live printable picture of sales sources, products and stock, cash, money out and vendors, with a saved dated copy as unchangeable evidence.

## Validation
- CI passed on SQLite and PostgreSQL for both PRs; full local suite 1,520 tests, zero failures; RuboCop clean.
- Rehearsal on a consistent copy of the production database using the exact source: migrate, rollback to `20261017150000`, re-migrate (integrity `ok`). On the copy the snapshot built from real data in 0.27 s; a synthetic statement imported two lines and a second upload skipped both as duplicates with the original byte-identical; a decision recorded who decided; Books check counted waiting lines. The copy was then deleted.
- Recovery point: private database backup `/var/backups/rupert/pre-bank-snapshot-20261017-100251` (integrity `ok`, no foreign-key violations). No Incus snapshot, by decision. Rollback: `git checkout bb8bf37` and a host-side `incus restart rupert`; the unused additive table can stay.
- After the host-side restart: web and jobs active, `NRestarts=0`, checkout clean at `9b6c35e`, migration version `20261017180000`, integrity `ok`, `bank_statement_lines` and `book_approvals` empty, `/up` and `/login` returned 200 on `pos.rupertpos.com`, signed-out `/snapshot`, `/bank_statements` and `/approve_books` redirected to login. No statements, approvals or test records exist in production.

## Not verified
The pages have not been viewed in a browser against live data, and the snapshot print layout has not been printed. Statement parsing was tested with synthetic CSVs; a real bank export may need column mapping.
