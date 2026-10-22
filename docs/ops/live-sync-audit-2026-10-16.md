# Live source audit — October 16, 2026

The Herbal Healers workspace on SER8 was inspected at 00:13–00:21 America/New_York. Live code advanced from `8c3118f` to `c79549b` through another window's POS release during inspection. This audit did not replace that checkout, deploy application code, restart services or execute any payment or merchant-setting operation.

## Verified source state

| Source/channel | Live evidence | Blocker and smallest remaining action |
| --- | --- | --- |
| SwipeSimple transactions and invoices | Fresh independent login and both native CSV previews passed at 00:16:59. A deliberate read then completed through the existing Solid Queue worker at 00:17:31, with diagnostic receipt `SYNC-6` succeeded and no error category. It validated 721 transaction rows and 332 invoice rows. | No current read blocker. Preserve the enabled 30-minute website schedule. Approved API/partner/scheduled-delivery entitlement remains unverified; no supported feed was invented or enabled. |
| C-Trax stock | Successful instrumented acquisition completed 00:15:33. | No current blocker. Preserve the approved stock connection and 30-minute cadence. |
| C-Trax daily sales | Successful separate receipts completed 00:05:06 and 00:05:10. | No current blocker. Stock success alone would not establish sales health. |
| Shopify catalog/orders | The 00:15 scheduled run completed successfully at 00:15:06 with a successful instrumented catalog receipt. | No current blocker. Preserve the 15-minute schedule and saved access. |
| C-Trax customers/employees and Shopify customers | All three directory states showed successful scheduled acquisitions shortly after 00:00. | No current blocker shown. Directory coverage remains separate from catalog and sales receipts. |
| NAB / IRIS native Daily Deposits | Connection complete/verified and last successful read 23:43:01 on October 15. Enabled daily website schedule registered for 06:45 Eastern. | No current blocker shown. This audit did not execute another NAB read or claim the upcoming timed run already happened. REST API entitlement remains separate. |
| Authorize.net reporting | Manual portal snapshot dated 21:41:02 on October 15; no reporting connection or API Login ID/Transaction Key saved. | Approved reporting access is needed before live API reads. Owner previously deferred key work; keep it deferred. Do not rotate a shared payment key, infer API access from portal sign-in or enable a schedule. |
| Square catalog/orders | Existing optional setup fields present, required access token absent. Latest scheduled catalog run skipped Square. | Save an authorized access token for the intended environment in Square setup when the owner elects to connect it. Do not generate, substitute or copy a different environment's token. |
| Google Drive instance backup | OAuth client fields present; no refresh token and no folder ID; no successful backup receipt. | Platform operator must complete the existing backup consent flow and verify a backup. A folder may be created by that service after authorization; the missing refresh token is the immediate access blocker. |
| Google Drive document retention | Disconnected and disabled; no refresh token. This is a separate connection from instance backup. | Owner previously deferred Google's Testing/test-user consent requirement. Keep it disabled. Follow the [recorded consent prerequisite](drive-retention-deployment-2026-10-16.md) when resumed, then verify upload/download receipts. |
| Valmar / PAX / KORONA / Cova | No configured reporting connection. Valmar/PAX are preparation objectives; KORONA/Cova remain unconfigured evaluation paths. | Establish the intended provider, supported read contract and authorized account access first. Setup cards are not working feeds. |

Google sign-in and Buzz showed configured required-field presence. They are auxiliary services, not proof of a financial source feed; this audit did not send a Buzz message or exercise a Google sign-in. (Note, 2026-10-22: Buzz has since been removed; see [team-chat.md](team-chat.md).)

## What appeared broken

SwipeSimple initially said **Awaiting observed success** despite a successful 00:00 website read. That read preceded diagnostic instrumentation deployment. The deliberate worker read created a real receipt and brought acquisition diagnostics current; historical timestamps were not relabeled as new receipts.

Shopify initially showed **Historical evidence stale** alongside a current source watermark because legacy fallback history selects source-specific `SyncRun` rows, while scheduled imports use source `all`. Its first new instrumented 00:15 success made current acquisition visible. No speculative credential repair was needed. The legacy fallback limitation remains relevant when inspecting a workspace before its first instrumented success.

Two retained failed `SyncJob` executions were historical, not a current blocked queue: a `SquareClient::Error` on October 14 and `Net::ReadTimeout` on October 15. Subsequent scheduled Shopify runs succeeded. They were retained as evidence, not retried or deleted. The worker heartbeat was current; no ready or scheduled execution backlog was present at inspection. Recurring registrations for the implemented sources were present.

## SwipeSimple integrity and preservation

The fresh preview used the saved encrypted credentials, a new server-side session and the existing read client. It validated both export kinds, row counts, schema and merchant identity without importing or changing connection settings. No browser session was extracted.

The subsequent normal manual-read job imported or reused native snapshots through the existing atomic service. Fresh-process readback verified both retained originals against their stored SHA-256 values, reparsed row counts against normalized row counts and confirmed encrypted original storage. Reusing identical export bytes remains a successful acquisition; it does not prove new transactions or complete historical coverage. Invoice numbers remain non-unique source labels, and these snapshots do not create a second canonical sale or inventory movement.

A consistent private SQLite checkpoint and protected configuration snapshot preceded the probe. Before/after verification confirmed unchanged encrypted credentials, authentication configuration, connection approval/account/environment fields, all existing sync flags, hosting/service configuration document-retention connection settings and the newer POS gateway configuration. Every previously saved source/document ID remained present; SQLite integrity and foreign-key checks passed. The CSV inbox environment remained absent/disabled. Website reads remained enabled every 30 minutes. Financial exports, account identifiers, tokens, ciphertext and private configuration digests are excluded from this record and Git.

Production rendering verified six source cards, independent C-Trax stock/sales channels, hidden saved secrets and no acquisition receipt created by rendering. Web/jobs were active, the live checkout was clean and public health returned HTTP 200.

No application fix or deployment was needed to restore the currently configured sales reads. Missing vendor authorization cannot be fixed by changing a worker, resetting credentials or turning on schedules. The operator guide was corrected to distinguish the working website schedule from the disabled CSV inbox and to state the actual Authorize.net five-minute cadence.

## Next repair sequence

1. Keep the working SwipeSimple website reader running and inspect its next timed receipt; treat website support/maintenance limits separately from proven read success. Keep local CSV intake disabled until an approved producer exists.
2. When owner access work resumes, complete the intended Square token, Authorize.net reporting access and the two separate Google authorizations through their existing secure setup flows. Do not put credentials in GitHub or chat.
3. Validate one bounded read/backup for each newly connected service before deliberately reviewing its existing schedule. Confirm intended source identity, saved originals and independent period totals; successful acquisition alone does not establish financial completeness.
4. Improve missing-access diagnostics and the legacy combined-run fallback in a separate reviewed change. Preserve the distinction between missing credentials, intentional pauses, queued work and an actual failed read. Outbound transition alerts and coverage reconciliation remain plan items, not delivered behavior.

Validation for this documentation-only change: live sanitized audit, independent SwipeSimple preview, real worker receipt and encrypted-original readback, protected before/after comparison, SQLite integrity/foreign-key checks, repository-local Markdown link checks and `git diff --check`. No application test rerun or deployment is claimed.
