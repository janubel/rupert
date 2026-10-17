# Combined release: migration and recovery — October 17, 2026

Application revision `96da4700b2ac3c05ee7b2aaa3f4ae1e23057d019` was deployed to SER8 and verified at 14:03 America/New_York (18:03 UTC). The checkout was clean at that exact revision. This combines the [financial consolidation (#107)](https://github.com/techmore/rupert/pull/107), [native Shopify count comparisons (#108)](https://github.com/techmore/rupert/pull/108) and [preserved live sign-in behavior (#110)](https://github.com/techmore/rupert/pull/110). [Exact-release CI checks](https://github.com/techmore/rupert/pull/110/checks) passed before promotion. The production runtime matches rehearsed source `c85dc9a`; the final release adds two regression tests.

The fresh post-deployment checkpoint was independently restored on SER8 and off-host. The final eight-page read-only rehearsal passed, final public health passed, and the shared deployment lock was released.

## Preserving concurrent work

Live preflight found the previously deployed `9b6c35e` source plus four uncommitted controller changes. They implement the operator's permission-checked bookkeeping landing preference, preserve that preference during dashboard customization/reset, and apply the same landing rules to password and Google login. The live patch was reviewed, retained privately and integrated into the combined release with regression coverage. Employee accounts continue to land in their personal workspace; a landing preference grants no additional access.

Before promotion, the previous source and controller changes were preserved in a local recovery commit. Its exact identity and the private recovery points are recorded outside public Git. The shared deployment lock, source-ancestry checks and exact-target guards protected the newer work. Rails `main` remains the production reference; the separate Rust track is unchanged.

## Migration and recovery rehearsal

- A current, consistent production SQLite backup was restored to an isolated copy using the existing production encryption keys. The rehearsal baseline contained 155 existing tables and 171,794 rows.
- The pending migrations were identified individually: `20261017130000` (encrypted Authorize.net portal observations and backfill) and `20261017190000` (append-only period-lock ledger). The lower-numbered observation migration was not inferred from the maximum migration version.
- Both migrations applied successfully. Explicit down/up rehearsal covered the observation migration and period-lock table; a repeat run verified actual idempotence. SQLite integrity and foreign-key checks passed.
- Existing records, 26 encrypted model sets and 794 retained files were preserved. The backfill produced 263 portal observations from retained source evidence. Originals and historical review/approval evidence remained intact; probes existed only on the isolated copy.
- An approved encrypted off-host recovery copy was decrypted outside Git. Every retained member passed its checksum, and the restored SQLite database passed verification. Private backup paths, source reports, credentials, encryption material and financial values remain outside this receipt.

This deployment pass did not initiate an Incus snapshot: the current `dir` pool can freeze production during the copy. Consistent database/configuration recovery points and the verified off-host copy were used for this pass. This does not describe or remove other operators' snapshots.

## Production verification

- Live migration preserved all 155 preexisting tables and their 171,893 rows, including changes made after the earlier rehearsal backup. It preserved 26 encrypted model sets and 794 retained files; 263 portal observations were backfilled.
- All 98 migration versions are recorded, including both `20261017130000` and `20261017190000`.
- The protected production environment remained unchanged. Web and jobs were active with `NRestarts=0` after activation.
- The existing schedules were retained; the reviewed quarterly and yearly reconciliation schedules were registered. No manual provider acquisition, payment, stock write, sync, reporting job or messaging job was invoked for this deployment. Normal scheduled work continues under its existing configured permissions.
- Public `/up` and `/login` returned HTTP 200. Protected books, period-lock, financial, stock and platform routes redirected signed-out visitors with HTTP 302; the inventory API returned HTTP 401.

The current post-deployment database, saved configuration, source and assets were sealed into a second encrypted recovery archive. Both pre-release and post-release off-host archives were decrypted in the approved private destination, with every archive member checksum and restored SQLite integrity/foreign-key check passing. Archive keys are stored separately outside Git.

Eight authenticated page renders passed against an isolated current database copy: Books desk, housekeeping checks, period locks, financial close, cash forecast, books check, daily reconciliations and stock comparison. Database writes were blocked, and full existing-table fingerprints before and after matched. These are read/render checks, not merchant acceptance.

The old orphan Puma and job processes were stopped through their verified service cgroups after a race-free idle check. Only the two application services were quiesced; no container restart, profile relaxation or instance snapshot was needed. Compiled assets and eager loading passed on the isolated candidate; frozen dependencies and both adapter CI suites passed. Final health and clean source were verified before releasing the shared lock.

## Release behavior and retained limits

The release includes Books desk and period locks, corrected financial-control interpretation and cash-forecast entry, indexed encrypted Authorize.net portal observations, native Shopify on-hand worksheet comparisons, customer navigation and payment credential isolation. Wallet/gateway client methods are implementation scope; merchant-specific acceptance, terminals, source stock correction and full POS cutover remain separate gates.

Submitted inventory comparisons and financial originals remain historical evidence. Informational-control changes can make affected daily reviews require review again; source/currency separation can change current period fingerprints. Inspect these changes without altering historical ledger events or treating deployment as acceptance of live balances. The [day-to-day pickup plan](day-to-day-readiness.md) retains the outstanding inventory and merchant acceptance gates.

## Safe rollback

For a compatible application rollback, use the preserved local recovery source, including the previously uncommitted controller work. Retain the current additive SQLite tables and all subsequent business writes, rebuild compatible assets and activate using the established SER8 procedure. Verify source, services, access, retained evidence and health again.

Do not restore an older database over newer transactions. A database restore requires an explicit current-write reconciliation/export plan; the frozen PostgreSQL cutover database is not a current recovery database. Do not disable AppArmor or change container privileges to force activation. Keep the private backup and source recovery commit after deployment.
