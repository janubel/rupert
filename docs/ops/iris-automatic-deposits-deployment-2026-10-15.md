# Automatic NAB Daily Deposits — October 15, 2026

The native Daily Deposits connector supports an encrypted NAB website login, fresh server sessions and a daily **06:45 America/New_York** schedule. It reads the current and previous calendar months separately for each configured merchant. A manual pull is available on the IRIS connection page and the dashboard bank card. REST reporting remains a separate mode requiring an approved API token.

## Implementation validation

- Combined local SQLite suite: **965 tests / 7,029 assertions**, zero failures/errors/skips. Configured RuboCop: **494 files**, no offenses.
- Fresh independent NAB login and downloads verified the intended two accounts and both months. Every CSV row, record count and amount/transaction total matched the merchant table response. Live files, signed download URLs, credentials and account identifiers remain private.
- The native website's `deposits` selector is used, not its separate batch report selector. The tests check this boundary and reject the other report's funding footer. CSV aggregate rows allow bounded empty padding only.
- Tests cover credential encryption/non-disclosure, scoped manual queueing, API/website separation, opt-in scheduling, stale setup, atomic preservation, replay, failed credentials/verification pausing, unsafe export destinations, identity mismatch and malformed responses.

## Authentication and failure behavior

Only the user's authorized username/password are persisted, encrypted in Rupert's connection. Each run creates its own ephemeral login/cookie/CSRF state; it never extracts browser sessions. Login state stays on the exact NAB tenant origin. Downloaded export files are restricted to the returned HTTPS URL under `cdn.iriscrm.com/nabankco/tmp/`, with no NAB cookie or CSRF header sent to that CDN. POST operations are limited to website login and fixed read/export GraphQL queries. No financial transaction or merchant configuration is changed.

A failed password or required additional verification pauses the connection and displays **Needs login**. A network/format error retains snapshots and displays **Error**. Concurrent setup changes reject obsolete results. The schedule requires an active workspace, authorized saved credentials and explicit opt-in. Removing credentials stops future imports. The previous-month refresh is bounded; older corrections require manual backfill.

## Activation record

Production activation and the guarded release revision will be recorded after promotion and the first scheduled-worker verification. Source validation is complete; this paragraph alone does not establish that the production schedule is enabled.

See [setup and operation](iris-reporting.md#automatic-native-daily-deposits-website-pulls) and the [earlier native CSV deployment](iris-native-deposits-deployment-2026-10-15.md).
