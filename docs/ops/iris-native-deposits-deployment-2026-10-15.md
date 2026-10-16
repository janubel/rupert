# Native IRIS Daily Deposits deployment — October 15, 2026

SER8 runs application revision `3a8787c6bd5cb5301a6699ae7ab65722d74aa57e`. The importer implementation is `59d059be2317592b58bd9a23ccce9c352596283e`; the deployed revision also preserves the newer SER8 source badges/manual reads/schedules and SwipeSimple integration research. Revision guards stopped preparation when production advanced, before any production mutation. The final prior revision was `56901c955a0caa86adcf82ad42d166990d833137`.

## Result

On **POS & payment connections → NAB / IRIS merchant reporting**, settings writers can now use **Import a native Daily Deposits CSV**. An approved NAB API token is not needed for file upload. Explicit merchant and source month context, native structure, record count, signed amounts and aggregate totals are validated before saving one encrypted `daily_deposits_csv` snapshot. Replays and corrections replace that merchant/month snapshot. Sales, inventory and ledger records are not generated.

The current format was checked against the real downloaded file privately. Native Health Center CSV/XLS formats and live REST authentication remain unverified; the six prior monthly Health Center observations remain transcriptions. No real Daily Deposits source file was imported into production by this deployment; the new upload workflow is ready for the operator.

## Validation

- Combined local SQLite suite: **941 tests / 6,774 assertions**, zero failures/errors/skips. Configured RuboCop: **485 files**, no offenses.
- Final focused authenticated-route tests, including denied native upload: **6 tests / 53 assertions**, zero failures/errors/skips. Tests also cover malformed/context-mismatched reports, atomic preservation, replay, corrections, tenant separation, encryption, signed amounts, leading-zero references and explicit empty reports.
- Real native CSV validated inside a rolled-back isolated test transaction. Source bytes and financial values were not committed or retained in the test database.
- Product site and documentation checks passed after incorporating the newer SER8 documentation.
- On SER8, production configuration and a private cloned database were used for migration/loader/assets/form/import rehearsal. All existing table counts were preserved; integrity and foreign-key checks passed. This feature needs no new migration.
- After promotion and host-side restart, web/jobs are active and public HTTPS `/up` returns 200. The production checkout is clean at the recorded revision. The new native form and existing monthly form render with an existing authorized account context. A synthetic native importer smoke check ran inside a rolled-back production transaction; no smoke report was retained and canonical order count was unchanged. This rendering check does not claim a new browser login or full authenticated browser upload.

GitHub runs for the deployed revision: [release branch CI](https://github.com/techmore/rupert/actions/runs/38838180840) and [PR CI](https://github.com/techmore/rupert/actions/runs/38838186263). These external runs were still running during deployment verification; the local and SER8 checks above completed successfully.

## Recovery

- Private consistent database/configuration/service backups: `/var/backups/rupert/pre-native-iris-20261015-3a8787c` (restricted directory; private files mode `0600`). A second consistent database backup and prior compiled assets were saved immediately before promotion.
- Incus recovery snapshot: `pre-native-iris-20261015-3a8787c`.
- Isolated rehearsal: `/var/tmp/rupert-native-iris-rehearsal-3a8787c`; source/assets stage: `/opt/rupert-native-iris-stage-3a8787c`.
- For a code rollback, first verify the live revision/checkout and preserve any intervening work. Restore the recorded prior code revision and compiled assets, then restart through host-side `incus restart rupert` and verify health. No database rollback is needed for this importer because its schema is unchanged. Preserve any legitimate reports uploaded after deployment; restoring a database or full snapshot would discard subsequent writes and is a separate recovery decision.

See the [operating instructions and format limits](iris-reporting.md#native-daily-deposits-csv) and [integration investigation](iris-integration-investigation.md).
