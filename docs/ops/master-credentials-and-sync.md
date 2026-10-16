# Master credentials and sync repair

## Operator workflow

Open **System → Credentials & sync** (`/connections`), also linked from the source cards, Settings and provider setup pages. This is the main setup desk for Rupert connections. Opening it reads local configuration/status only; it does not contact vendors, queue jobs, change schedules or process payments.

1. Find the source in **Sync health & repair**. Green means the displayed status is current/healthy or in progress; red identifies a paused, stale, manual-only, unconnected or failed source. Read the badge and repair text, rather than relying on color alone. Portal snapshots are evidence, not proof of automatic access.
2. Open **Review setup** or the service's **Manage setup**. Shopify, Square, warehouse Authorize.net, Buzz and Google sign-in have named credential forms. C-Trax, SwipeSimple, Authorize.net reporting, NAB/IRIS, Valmar, PAX and evaluation providers retain their existing provider-specific forms and instructions. Google Drive instance backup setup stays with the platform operator.
3. Obtain credentials for the intended account, environment and integration method. Merchant login, gateway credentials, processor API tokens and browser access are separate kinds of access. C-Trax inventory authentication remains separate from TRX merchant credentials; Authorize.net reporting remains separate from warehouse checkout credentials.
4. Save deliberately. Blank secret inputs retain saved values; explicit removal checkboxes remove only selected fields from Rupert. A replacement and removal for the same field are rejected. Saving queues no job or access check. Existing enabled schedules may pick up the new values on their next run; review the provider schedule separately.
5. Run **Check read access** where a documented check is implemented, then use **Read source now** or the provider's import page. These are explicit actions with their existing permission gates. A check proves its specific operation at that time; it does not prove payment readiness, settlement, complete history or continuous delivery.
6. Confirm source freshness and coverage after the read. If access works but data remains stale, inspect Sync history; ask the operator to inspect Worker status and the deployed scheduler. Do not rotate credentials simply because a job is delayed.

The hub exposes no bulk “fix everything” action. Credential replacement, vendor checks, reads, scheduling and payment operations have different consequences. Repairs should target the diagnosed source and preserve unrelated working connections.

## Access and secret handling

- An active workspace/account and `settings.read` are required to inspect the hub. Editing requires `settings.write`. Existing `sync.write`, C-Trax `inventory.write`, reporting and provider-action permissions still apply; this change grants no new permissions.
- Only a fresh active platform super administrator sees Google Drive instance-backup setup/status in this hub. Tenant administrators cannot edit platform backup fields through the named forms. Encryption, database, hosting and boot-time application credentials remain operator-managed.
- Named forms write the existing encrypted tenant `Setting` rows. Provider forms continue using encrypted tenant `PosConnection` credentials. There is no second credential copy, new plaintext vault or migration. The hub reports Saved/Missing/Unreadable; it shows neither saved secrets nor fragments of them. Nonsecret saved values such as store domain are displayed for account review; replacement inputs start blank.
- Saves use a signed, expiring 15-minute form bound to actor, workspace, service and database-setting versions. A tenant writer lock serializes the version check and write. Changed, expired or foreign forms require reload; invalid fields/environment/removal conflicts fail before any credential changes. Form tokens contain version metadata, not secret values or password hashes.
- The entire credential form container is filtered by the existing request-log filters. Audit entries name the service only. Pages are `no-store`, disallow Turbo snapshot caching and use a no-referrer policy. Validation failures do not echo submitted values.
- If existing values cannot be decrypted, the hub identifies the problem and named forms refuse to overwrite them. Restore the original encryption keys from the protected backup with the platform operator. Generating replacement keys is not credential recovery.
- Removing a Rupert field does not revoke the vendor credential. Shared Authorize.net Transaction Key rotation must be coordinated with all checkout consumers; a reporting repair must not silently break a working checkout. The older password-gated operator `.env` export remains a separate existing workflow, outside this hub.

## Improvement plan

| Priority | Deliverable | Acceptance |
| --- | --- | --- |
| 1 — implemented here | One setup desk with named forms, source health, provider check links, explicit reads and troubleshooting | No secrets/fragments in hub HTML; tenant and role isolation; stale/foreign form rejection; atomic updates; no vendor call/job on page load or credential save; existing schedules unchanged. |
| 2 — next | Shared structured health contract for every connector | Credential completeness, check status, last attempt, last successful acquisition, source event/export time, coverage and worker health are separate fields. Missing data is not zero. An old failure cannot override newer verified success. |
| 2 — next | Actionable failures and job progress | Stable categories for missing entitlement, rejected credentials, extra sign-in verification, schema drift, incomplete pagination/export, throttling, timeout and worker failure. Show a sanitized next action, queue state, retry time and support reference without raw responses. |
| 2 — next | Source freshness and delivery alerts | Per-source expected cadence; alert on meaningful stale/failure transitions, not unchanged state. Successful retries/replays do not imply advancing source coverage. Manual-only sources remain explicitly manual. |
| 3 — planned | Credential responsibility and review | Named owner, scope/environment, intended consumers, last review, next review, approved vault item reference and access-check receipt. Keep rotation dates distinct from vendor expiry facts; do not invent expiration dates. |
| 3 — planned | Coordinated rotation and recovery | Review all consumers of shared keys; provision securely, validate a read, coordinate cutover, verify old-key revocation and rehearse recovery with existing encryption keys. Do not automate merchant key generation or broad permission grants. |
| 3 — planned | Provider-supported unattended feeds | Obtain account entitlement and delivery/schema contracts, handle historical corrections/replay and verify independent period totals before activating a schedule. Website reads remain clearly identified with their support and maintenance limits. |

Implement priority 2 before adding a global repair button or claiming that “configured” means “healthy.” The current hub reuses source status logic and local evidence; it cannot independently prove the job worker is running or that a vendor has granted a supported API. The existing host/worker diagnostics remain the operator's verification path.

## Validation and rollout

Tests cover secret-free rendering, filtered parameters, active-workspace/role boundaries, platform setup exclusion, tenant/actor/service binding, expiry and stale forms, atomic validation, explicit removal and preservation of blank secrets. Existing provider/source tests protect their action gates. Use synthetic credentials and isolated databases for validation; real credentials, source exports and account references do not belong in public Git.

No production credential, schedule, merchant setting or database migration is changed by this implementation. Review the source change and deploy through the established release process, preserving all current SER8 work. After deployment, inspect the hub as a workspace reviewer, workspace administrator and platform operator. Test real vendor checks only with authorized account access and keep their private evidence outside Git.
