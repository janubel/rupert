# Employee source history deployment — October 17, 2026

**Deployed and verified.** Live migration, complete source imports, authenticated access/render checks and pre/post-deployment recovery verification succeeded at revision `b9fe783917bb70ddfa273ffbec7449be93c61883`.

[PR #118](https://github.com/techmore/rupert/pull/118) adds unfiltered Square/C-Trax history links from Timesheets, reviewer/all-employee filters, latest clock and Square break punches, original source evidence, safe CSV and immutable C-Trax observations. Existing authentication changes remain included. The exact implementation candidate passed final CI and restored-copy rehearsal before promotion.

## Live migration and health

Promotion used the shared deployment lock, exact source/environment guards, idle/frozen workers and a fresh quiesced SQLite checkpoint. The expected migration added the C-Trax shift and observation tables. The live preservation receipt verified all **157 pre-existing tables / 172,474 rows**, **28 encrypted model sets** and **794 retained original files** unchanged. Integrity and foreign-key checks passed. No older database was restored over current records.

Public health returned HTTP 200 with `X-Rupert-Build` matching the deployed revision. Both source-history routes returned HTTP 302 for signed-out requests. Authenticated access verification also passed on the deployed build with writes blocked: four eligible reviewer scopes saw all retained source records, and eight active employee scopes matched only their own records. Thirteen page/CSV renders returned HTTP 200 with `no-store`; CSV row counts and latest punches matched retained evidence. All 24 C-Trax observations were present. Verification decrypted all 30 encrypted model sets, read all 794 retained originals and checked 99 applied migrations, database integrity and zero foreign-key violations. Existing login/setup links remained unchanged.

## Complete source reads

| Source | Total records | Imported | Conflict | Open | Unassigned | Unmatched |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Square | 911 | 907 | 1 | 3 | — | — |
| C-Trax | 24 | 13 | 7 | 0 | 2 | 2 |

The C-Trax import retained **24 immutable observations**. Unassigned records retain a native employee identity and available clock/hour evidence without inventing a missing store assignment. Unmatched and conflicting records remain review evidence. Source-reported hours and elapsed clock time remain separate, and missing C-Trax break punches are not inferred.

These aggregate source statuses do not establish approved or payable hours, employment status or payment. Counted Square history retains its existing personal-report/calendar treatment. C-Trax history remains excluded from personal hour totals and Rupert payroll. The imports create no Rupert approvals, pay rates, overtime classifications or payroll payments and do not mutate upstream timecards. Overlapping Rupert/Square/C-Trax hours are not added automatically.

**C-Trax automatic labor refresh is not scheduled.** This receipt covers the completed manual source read. Square retains its existing opt-in refresh schedule.

The live Square feed contained no break punches. Break-punch display/export capability is covered by synthetic tests; this receipt does not claim that real break-punch data was returned. C-Trax breaks remain unavailable and are not inferred.

## Access and recovery status

- Complete: final candidate CI and restored-copy migration/render rehearsal; live migration preservation and source reads; public build health, signed-out route checks and authenticated reviewer/own-worker page/CSV verification.
- Complete: the pre-deployment sealed recovery copy was verified off-host in the private recovery destination.
- Complete: the consistent post-import database, source, environment/encryption keys, assets and service configuration were captured in an AES-256 encrypted archive. Decryption, every archive member, SQLite integrity and zero foreign-key violations were verified on SER8 and independently in the approved off-host recovery destination. The off-host copy also confirmed migration `20261017220000` and retained C-Trax shifts/observations against the import controls.
- Complete: web and job services were healthy with zero recorded restarts, and the shared deployment lock was released.

Verification did not submit, approve or pay real hours. Recovery locations, source payloads, employee identifiers, credentials and encryption keys remain private. Any rollback must preserve newer employee/business records and both new history tables rather than restoring an older database.

See the [source-history guide](employee-source-history.md), [Square refresh/counting rules](square-timecard-history.md) and [employee workflow](../employee-timesheets.md).
