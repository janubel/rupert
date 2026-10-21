# Private workspaces and instance administration

Reviewed 2026-10-15. A company can request its own private Rupert workspace on this installation. Platform administrators review new setup requests and see installation-wide totals in a separate private dashboard.

## Request a workspace

Open [Request a private company workspace](https://herbalhealers.rupertpos.com/signup), also linked from the sign-in page. Enter a workspace name, a preferred workspace address label and the company's email domain. Continue with a Google account whose verified email matches that domain. Common consumer email domains are excluded from this company-workspace request flow; existing approved users can continue signing in normally.

The request is saved for platform review. Submitting it does not create an active workspace, sign the applicant into another store or reserve the requested address. Google confirms the email identity, not legal ownership of the domain. The platform administrator should confirm the applicant's authority to represent the company before approval. Password-only self-registration and non-Google identity providers are not included in this release.

The callback shows a private receipt for the verified request. There is no public request directory or record lookup link. Repeating a request with the same verified identity retains its current review state; rejection does not silently reopen it. There is no automatic approval email or background invitation message. After approval, the applicant can sign in with the same Google identity at the shared Rupert login address. The initial owner is bound to that approved Google account; reassigning its email address to a different Google account does not grant owner access.

The preferred workspace address is a label within Rupert. Saving it does not configure DNS, issue a TLS certificate or host the application on the company's own domain. The shared instance login works without a new custom hostname. Custom application domains and wildcard hosting require separate operator setup.

## Review new setups

An active platform super-admin can open [Instance overview](https://herbalhealers.rupertpos.com/platform), also available through the **Instance** header link and **System → Instance overview**. Ordinary store administrators and staff cannot open it, including accounts with delegated settings permissions.

The dashboard shows all-workspace and account totals, seven-day account creation, thirty-day workspace creation, active/inactive workspaces, pending/approved/rejected requests, allowed email-domain entries, saved provider setups and API-token counts. Pending requests have pages of up to 20 records; recent completed reviews and workspaces are limited to their latest 20 records. Totals cover the installation rather than only the visible page. Account counts represent Rupert user records, not unique human beings, paying subscribers or currently signed-in sessions. An active account flag does not override an inactive workspace.

Review the applicant, company domain and requested address, then explicitly approve or reject the request. Approval creates a new workspace, its first store administrator, its allowed sign-in domain and local finance defaults together. It copies no merchant credentials or existing store records and starts no provider sync. Concurrent or repeated reviews cannot create duplicate workspaces; a conflict leaves the setup uncreated. Review events retain the actor, time and encrypted before/after attribution.

Later Google users from an enabled, unambiguous company domain receive a reader account. Store administrators assign additional permissions separately. Root sign-in uses an existing exact account first and refuses ambiguous domain-only routing. Inactive accounts and workspaces cannot sign in or retain an authenticated workspace session.

## Referral attribution

New public Google accounts and approved signup workspaces receive the configured default referral label automatically. The private dashboard shows that exact label and account counts by attribution. It is an owner-supplied attribution value; it is not checked as a website, payout account or verified referral partner. Existing accounts and workspaces keep their prior attribution, including an unrecorded value.

Referral attribution does not enroll the applicant in the referrer's store, grant the referrer access to customer records or share payment credentials. Referral payouts, commissions and billing are not automated by this label.

## Installation information

The instance section shows its configured deployment label, database adapter/schema and, for SQLite, the SQLite version, journal mode and main database-file size. The main-file size excludes WAL, temporary files and total container storage. Set `RUPERT_INSTANCE_LABEL` in the protected deployment environment to identify the offering; this is an operator label, not an automatic discovery or health check of SER8/Incus.

Job counts and recent heartbeat records describe the queue database at page generation time. Recent heartbeats are not verified operating-system process counts. The dashboard also shows the latest recorded successful sync and completed backup upload when present. An upload record is not proof of a tested restore; separate private backups and Incus snapshots are not discovered here. Opening the dashboard runs no sync, provider check, backup or host command.

Whole-database backup/restore and Google Drive backup configuration, consent, status and history are platform-administrator controls in Settings. These snapshots contain all workspaces. Existing workspace-owned Drive connections are ignored; a platform administrator must explicitly configure and authorize the instance destination, or supply trusted host configuration. Scheduled Drive uploads run once per instance, never once per workspace. Platform super-admin is Rupert's highest application role; it is not a new operating-system login, SQL console or database password. No Incus socket or container-management API is exposed through the application.

## Privacy and recovery

Applicant details, signup reviews and cross-workspace totals stay inside the authenticated application. Private dashboard and signup responses prevent caching and embedding. Public GitHub Pages describe the workflow without publishing account lists, applicant data or setup history. Protect printed records, database backups and encryption keys through the existing operations process.

Rehearse the additive migration on a private SQLite copy, preserve existing account and business rows, take a consistent backup and retain a recovery snapshot before deployment. Keep the conservative queue concurrency default. See [SQLite and Incus operations](https://techmore.github.io/rupert/sqlite-incus.html) and [private owner records](https://techmore.github.io/rupert/owner-checklists.html).
