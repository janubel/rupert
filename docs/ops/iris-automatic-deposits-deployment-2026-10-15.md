# Automatic NAB Daily Deposits — October 15, 2026

The native Daily Deposits connector supports an encrypted NAB website login, fresh server sessions and a daily **06:45 America/New_York** schedule. It reads the current and previous calendar months separately for each configured merchant. A manual pull is available on the IRIS connection page and the dashboard bank card. REST reporting remains a separate mode requiring an approved API token.

## Implementation validation

- Combined local SQLite suite: **996 tests / 7,254 assertions**, zero failures/errors/skips. Configured RuboCop: **521 files**, no offenses.
- Fresh independent NAB login and downloads verified the intended two accounts and both months. Every CSV row, record count and amount/transaction total matched the merchant table response. Live files, signed download URLs, credentials and account identifiers remain private.
- The native website's `deposits` selector is used, not its separate batch report selector. The tests check this boundary and reject the other report's funding footer. CSV aggregate rows allow bounded empty padding only.
- Tests cover credential encryption/non-disclosure, scoped manual queueing, API/website separation, opt-in scheduling, stale setup, atomic preservation, replay, failed credentials/verification pausing, unsafe export destinations, identity mismatch and malformed responses.

## Authentication and failure behavior

Only the user's authorized username/password are persisted, encrypted in Rupert's connection. Each run creates its own ephemeral login/cookie/CSRF state; it never extracts browser sessions. Login state stays on the exact NAB tenant origin. Downloaded export files are restricted to the returned HTTPS URL under `cdn.iriscrm.com/nabankco/tmp/`, with no NAB cookie or CSRF header sent to that CDN. POST operations are limited to website login and fixed read/export GraphQL queries. No financial transaction or merchant configuration is changed.

A failed password or required additional verification pauses the connection and displays **Needs login**. A network/format error retains snapshots and displays **Error**. Concurrent setup changes reject obsolete results. The schedule requires an active workspace, authorized saved credentials and explicit opt-in. Removing credentials stops future imports. The previous-month refresh is bounded; older corrections require manual backfill.

## Activation record

SER8 runs `31a6fac3dd52c8c3dc64b0560d3db8b345fff9cb` (website connector implementation `c397cb0`). The release preserves the newer marketing, reconciliation, dashboard and website-import changes already deployed at prior revision `1cecc3458e97adfae2b3434ef6da9b7e4a011cdf`.

A consistent private database/configuration/service backup was taken at `/var/backups/rupert/pre-native-iris-20261015-31a6fac`; Incus snapshot `pre-automatic-nab-20261015-31a6fac` precedes promotion. Loader/migration/assets/form/importer rehearsal used a private cloned production database and preserved all existing table counts. No new migration is required by the NAB automation. Activation used host-side container restart; web/jobs are active, the checkout is clean and public HTTPS health returns 200.

The owner's authorized NAB login was saved encrypted, the two intended merchant accounts were explicitly configured, and daily imports were enabled. A job queued through the normal Solid Queue worker completed successfully, saving the four current/previous-month snapshots. Fresh-process readback confirmed saved row/count/amount consistency, preserved Health Center observations and unchanged canonical order/order-line/payment/ledger counts. The bank dashboard reports **Live**. The actual recurring task is registered for **06:45 America/New_York**, with its next run confirmed by the scheduler's cron parser. Sign-in cookies and signed export URLs were not persisted. Temporary plaintext credential files used for activation were removed after verification.

The deployed revision passed [GitHub PostgreSQL and SQLite CI](https://github.com/techmore/rupert/actions/runs/38842179324), plus product-site checks. Private account IDs, amounts, file digests, source observations and the activation/worker receipt remain outside public Git.

For recovery, pause the NAB schedule before restoring the prior code revision, since the old code lacks the `web` authentication mode. Preserve the current encrypted connection and imported snapshots privately; do not restore a database backup merely to revert code, because that would discard later legitimate writes. Restore prior compiled assets and restart through the host workflow. Keep the existing encryption configuration intact.

See [setup and operation](iris-reporting.md#automatic-native-daily-deposits-website-pulls) and the [earlier native CSV deployment](iris-native-deposits-deployment-2026-10-15.md).
