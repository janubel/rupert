# Timesheet review release and recovery — October 17, 2026

The SER8 application was already running clean revision `b5e2a40a171f043709f2afcd9763040ecc876e8b` when this verification pass began. This pass identified the existing deployment rather than redeploying an older checkout or restarting healthy services. That revision includes [timesheet review #112](https://github.com/techmore/rupert/pull/112) and retains the earlier [combined financial/inventory release](combined-release-recovery-2026-10-17.md). Main subsequently added the combined-release documentation checkpoint; documentation commits do not imply another application deployment.

## What changed

Timesheets has a named top-level workspace. Active administrators, managers and permitted reviewers open the submitted queue by default, can inspect all/approved/returned sheets, and see an explicit review checklist. A new `shift_leader` role grants POS, dashboard and timesheet read/review access without payroll or account administration. No existing account is assigned that role by this release. Explicit permission overrides continue to apply.

Reviewers cannot approve their own linked employee's hours. Approval now rechecks active employment, retained entry validity, daily totals, imported clock hours and unresolved clock corrections; returning a sheet remains available when correction is required. Employee self-service boundaries, immutable submitted entries, review events and payroll locking remain in force. These controls support an operational pilot; they do not establish payroll policy or real-device/operator acceptance.

The source delta introduces no database migration, dependency, provider connector, service configuration or recurring-schedule change. The existing migration set must remain complete; checking only the maximum version is insufficient.

## Evidence recorded in this pass

- Live source was verified at `b5e2a40a171f043709f2afcd9763040ecc876e8b`, with a clean checkout and active web/jobs reporting `NRestarts=0`.
- A fresh consistent current SQLite checkpoint includes the legitimate employee/account identity repair made after the earlier combined deployment. All 98 schema versions are recorded and no migration is pending.
- The encrypted recovery archive was independently decrypted on SER8 and in the previously approved private off-host destination. Every member checksum passed, both restored databases passed integrity/foreign-key checks, and the later Google identity/employee linkage was verified in the off-host copy. The archive key is stored separately outside Git.
- All 28 encrypted model sets were decrypted with the saved configuration, and 794 retained files passed checksum/size checks. The later Google login repair, its active linked employee and the existing platform administrator are present in this fresh checkpoint.
- Six authenticated renders returned HTTP 200 against the fresh isolated copy with database writes blocked: the four reviewer queue filters, an existing timesheet detail and the employee’s own timesheet list. The employee list had no review controls. An unsaved shift-leader permission probe allowed review while denying editing other workers’ hours, payroll and account administration; no account role was changed.
- Full fingerprints for all 157 existing tables and their 171,950 rows matched before and after the isolated read-only checks. These demonstrate that verification did not alter the copied records; they do not reconstruct a before/after comparison of the earlier deployment.
- [PR #112 CI](https://github.com/techmore/rupert/pull/112/checks) passed. An independent focused authorization/workflow check passed 24 tests and 167 assertions.
- Final live source remained clean at `b5e2a40a171f043709f2afcd9763040ecc876e8b`; protected environment configuration was unchanged and web/jobs were active with `NRestarts=0` each. Existing quarterly/yearly financial schedule registrations were retained. Public `/up`, `/login` and `/employee` returned HTTP 200; signed-out `/people/timesheets` returned HTTP 302, and employee-timesheet/inventory APIs returned HTTP 401. The shared deployment lock was released and confirmed available.

This pass inspected the existing deployment and verified fresh private recovery copies. It changed no application source, restarted no service and performed no production role, timesheet, clock or payroll writes. No provider/payment/stock action or manual sync job was invoked. Normal configured schedules continued.

Private recovery paths, employees, account identifiers, credentials, encryption material and employment records remain outside public Git. Saved recovery records are current checkpoints; earlier backups remain historical recovery evidence.

## Safe rollback

Prefer a forward fix when practical. A compatible source rollback must retain the current database, timesheet reviews/events, payroll snapshots and all newer login/account repairs. Never restore the older combined-release database over later business records.

Before reverting to source predating this release, check for any `shift_leader` account or role configuration introduced since deployment. Older source does not recognize that role. Preserve its stored assignment and arrange an explicit compatible-role/forward-code plan rather than silently changing or dropping it. Restore compatible assets and use the established guarded service procedure if activation becomes necessary. Retain the private recovery archive and verify health, authorization and current records again.

## Next daily-use gates

Name the staff reviewer, assign minimum permissions explicitly, and pilot employee entry → submission → review → return/correction or approval with designated test records and operator consent. Confirm that overtime classification, pay-period rules and payroll treatment match the business's approved policy. Native signing/distribution and actual device acceptance remain separate steps. Continue the payment and physical-inventory gates in the [day-to-day pickup plan](day-to-day-readiness.md).
