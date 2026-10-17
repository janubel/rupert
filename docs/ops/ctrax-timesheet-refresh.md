# Automatic C-Trax timesheet refresh

Release status: **implementation pending live deployment and activation verification**. The previously verified [source-history release](employee-source-history-deployment-2026-10-17.md) performed a manual C-Trax read. It did not activate this schedule. This guide describes the automatic refresh implementation and its operating limits.

## Enable or stop refresh

Open **Timesheets → View C-Trax history**. An active account administrator with `users.write` and `timesheets.write` can enable or disable automatic refresh there. A configured, vendor-approved C-Trax connection with saved credentials in the expected format is required to enable it. Enabling checks configuration; the subsequent source read must still authenticate and succeed. A reviewer can inspect refresh status without gaining configuration permission; ordinary employees retain their own history without administrator controls. The setting is specific to the current workspace and records the authorizing administrator and a configuration revision in encrypted storage.

Once enabled, the server dispatches a C-Trax labor read every 15 minutes, at minutes **02, 17, 32 and 47** of each hour. The application job worker and recurring scheduler must both be running. Leaving the history page or closing the browser does not stop server refresh. Disabling the setting stops future publication, including an in-flight read whose setting revision no longer matches. Re-enabling creates a new revision; an earlier authorization cannot silently replace it.

Refresh configuration does not create employee accounts, invitations or permission grants. If the authorizing account is deactivated, moves to another workspace or loses the required permissions, publication is denied until an authorized administrator configures the schedule again. Changing the saved source credentials during a read also prevents that read from publishing. Existing source history remains retained.

## Status and pickup limits

The C-Trax history page shows the last successful recorded read and the latest queued, running, succeeded or failed timecard-read attempt using safe status information. These receipts can include reads recorded before the automatic schedule was enabled; a successful old receipt alone does not prove that recurring dispatch is active. An estimated next scheduled slot is a dispatch estimate, not a completion promise. Check both the attempt result and last successful read when reviewing freshness.

A change made just after a scheduled slot normally waits until the next slot before dispatch, then waits for worker availability and a complete read. Queue delays, source availability and validation can extend that interval; this is not an instant or guaranteed 15-minute source-to-screen service. An unchanged successful refresh advances freshness without appending duplicate C-Trax observations.

Each run reads the complete available closed and open labor feed for the configured account. It does not restrict the read to today or infer a native store/date query that the endpoint does not support. The existing client bounds apply: at most 20 accessible stores, 200 pages per feed, the configured row cap, 2 MiB per response, 32 MiB per client session and a 90-second client request budget. Very large histories are rejected rather than silently truncated. A per-workspace job concurrency limit bounds overlapping scheduled work.

Remote pagination and the separate closed/open reads are not a point-in-time source transaction. A shift changing state while those feeds are read can cause validation to reject the attempt or leave a change for the next successful read. Failed authentication, incomplete pagination, duplicate IDs, unexpected source scope/schema or changed authorization/configuration prevent local publication. Prior rows, hours and immutable observations stay available. A per-origin publication revision rejects an overlapping read if another complete read has published since it began, including a newer empty read; last-seen timestamps keep their source-presence meaning. A later scheduled attempt retries normally; an operator should investigate repeated failures rather than treating a stale snapshot as current.

## Source evidence and payroll

Native C-Trax employee identities resolve through retained source identities and confirmed consolidations. Missing employee matches, inactive historical employees and shifts without a store assignment stay explicit history rather than being guessed, activated or discarded. Original punches/hours remain unchanged, latest source values remain visible separately and each observed source/status change appends immutable encrypted evidence. The schedule can record only changes that Rupert actually observes between reads.

C-Trax reported hours and elapsed clock time can differ. Break punches and payable adjustments are not inferred. Automatic reads do not approve hours, classify overtime, change HR/pay rates, create Rupert timesheets or payroll payments, or mutate C-Trax timecards. C-Trax history remains excluded from personal hour totals and payroll; overlapping Square, C-Trax and Rupert hours must not be added together. See [employee source history](employee-source-history.md) for punches, CSV access and retained evidence.

## Deployment and activation verification

This scheduler uses existing encrypted tenant settings and retained source-history tables; it adds no database migration. Preserve the currently deployed authentication and business records, take consistent private recovery checkpoints and verify the restored copy before promotion. Enable only the intended workspace through an authorized administrator after the deployed build is verified. Then verify actual recurring dispatch, worker execution, complete read publication and page freshness without creating or approving real employee hours. Verify disable/revocation and unchanged-replay behavior with controlled tests; keep credentials, employee identifiers and raw source payloads outside public documentation.

Record the actual live activation and recovery evidence before changing this guide's pending release status. The [manual source-history deployment receipt](employee-source-history-deployment-2026-10-17.md) remains a historical receipt rather than proof that this new schedule is active.
