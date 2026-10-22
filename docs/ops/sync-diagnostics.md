# Sync diagnostics and repair

Open **System → Credentials & sync** (`/connections`). Each implemented source
now separates source/snapshot status from acquisition diagnostics. C-Trax stock
and daily sales have independent channels; Square acquisition appears in its
credential card. Credential completeness and access-check time remain in the
existing setup cards. Valmar and other evaluation providers do not gain a feed
merely because a setup card exists.

## Reading the evidence

- **Last attempt** is the start of an instrumented read. A queued job is not an
  attempt or successful acquisition. Before rollout, precise attempt times and
  categories may be unknown; existing timestamps are labeled separately.
- **Last successful acquisition** means the existing importer completed, or the
  existing backup completed verification. An identical export replay can be a
  successful acquisition without advancing source activity. A busy concurrent
  read is skipped and never counts as success.
- **Stored source / export timestamp** reuses the connector's existing timestamp
  semantics. It is not relabeled as the latest payment or a complete event-time
  watermark. Event coverage remains explicitly unrecorded where no verified
  coverage contract exists. Stored date ranges can have gaps; report windows
  can overlap and must not be summed.
- **Queue** is a local Solid Queue receipt linked to the instrumented attempt's
  Active Job ID. Only an actual scheduled execution supplies a retry time.
  Ready, claimed, blocked, scheduled and failed states are distinct. A pruned
  queue receipt is unknown, not proof of success. Per-connection enqueues and
  explicit catalog jobs record queue receipts; global scheduler dispatches are
  recorded when their individual reads begin. Bulk enqueues bypassing Active
  Job callbacks similarly acquire receipts when reads begin.
- **Worker evidence** reports a recent (two-minute) Solid Queue worker heartbeat
  or its absence. It does not prove this source's schedule is registered or
  that every queue has a worker. Non-Solid Queue adapters and unavailable queue
  storage are unknown. No hostnames, PIDs or unrelated job arguments are shown.
- **Support reference** identifies a tenant-scoped `SYNC-…` receipt. Give the
  operator this reference and the displayed category; do not paste passwords,
  private exports or raw vendor responses into a public issue.

The newest read by start time wins, with queue time used before execution starts.
An older failing read that finishes after a newer success cannot replace it.
C-Trax sales failures cannot overwrite stock health. A new failure retains the
previous successful acquisition timestamp and source snapshots.

## Missing access versus a paused schedule

**Current read setup** reports local required-field presence and Rupert's saved
read-authorization confirmation separately from attempt results and schedule
opt-in. Missing setup lists static field names only, including the intended
company/gateway/merchant reference when required. Optional Square fields do not
block a token-backed read. NAB website/API and Authorize.net OAuth/API modes use
their own required fields. Presence does not prove vendor entitlement.

A source with missing setup shows **Missing access**, or **Read authorization
required** when only Rupert's read confirmation is absent. A configured source
whose opt-in is disabled retains **Automatic reads paused**. No credential,
approval flag or schedule is changed by this projection. A queued/running job or
recorded failure retains its own status and support reference while current
missing setup remains visible alongside it. Previous successful acquisitions
are retained when credentials are later removed.

Unreadable saved credentials require restoration of the original encryption
keys and must not be described as missing fields. Backup-specific setup and
consent diagnostics are deferred; their existing behavior is unchanged.

## Legacy catalog evidence

Before a source's first instrumented receipt, Shopify legacy evidence includes
successful `SyncRun` rows with source `shopify` or `all`. A combined run always
imports Shopify; it can skip Square, so a combined success does not establish a
Square read. Both sources also recognize their own saved acquisition watermark,
which advances only after that source's import completes. This preserves
Shopify evidence when a later stage of a combined run fails. Watermark times are
run-start acquisition evidence, not completion or event-coverage timestamps.

The newest valid source watermark or applicable successful legacy finish time
is shown as **Legacy success evidence**. Invalid timestamps and future
watermarks are ignored; malformed Shopify watermarks no longer break the source
cards. All lookups remain scoped to the workspace. Fresh legacy evidence avoids
a false **Historical evidence stale** alert but remains **Awaiting observed
success** until an actual instrumented success exists. It creates no attempt,
last-attempt time or successful-acquisition receipt. A new instrumented failure
still wins over older legacy evidence.

## Failure categories and repairs

| Category | Meaning | Next action |
| --- | --- | --- |
| Setup incomplete | Required configuration was rejected | Review the intended account/environment and required fields, then check read access. |
| Credentials rejected | A typed authentication failure | Verify saved credentials and environment. Coordinate any shared payment-key change with its other consumers. |
| Read permission denied | Explicit permission/entitlement denial | Confirm vendor reporting scope with the account administrator; portal sign-in is not API entitlement. |
| Vendor access denied | A vendor code does not distinguish authentication from scope | Review identity, environment, authentication and read grants together. |
| Additional sign-in verification | Vendor requires another sign-in step | Complete verification and check access, then deliberately review scheduling. |
| Source account mismatch | Requested and returned account identity differ | Review setup; retain previous snapshots and do not import another account to hide the error. |
| Unexpected or incomplete source data | Contract/export/pagination validation failed | Operator inspects the connector contract; do not accept truncated data. The shared upstream response code does not identify which validation failed. |
| Vendor rate limit | Explicit throttling response | Wait for a recorded retry or existing schedule; avoid repeated manual reads. |
| Read limit exceeded | Connector size/time bound reached | Use a smaller supported window where possible; review limits rather than truncating. |
| Network / secure connection failure or timeout | Transport failed | Check vendor availability and server connectivity/TLS; preserve credentials. Some clients combine transport and timeout into one safe upstream reason. |
| Vendor service failure | Explicit upstream server error | Check service availability and retry after recovery. |
| Setup changed during read | Concurrent setup version changed | Reload current setup and retry once; never restore obsolete credentials. |
| Saved credentials unreadable | Existing encryption failed | Restore the original runtime keys with the platform operator; do not replace saved credentials or generate new encryption keys. |
| Local storage failure | Database operation failed | Inspect database availability, disk space and locks. |
| Job did not complete | Queue failure or aborted job before a source read | Inspect worker/queue using the support reference; changing passwords will not repair a worker. |
| Cause not recorded precisely | Legacy or unclassified error | Review evidence with the operator. Do not infer a credential failure from arbitrary error text. |

Categories come from trusted typed reasons, numeric HTTP statuses and Shopify's
documented GraphQL extension codes, never free-text matching. Shopify can return
errors with HTTP 200; see its [2026-07 Admin API error contract](https://shopify.dev/docs/api/admin-graphql/2026-07#status-and-error-codes).
New Shopify/Square error messages omit vendor bodies. Invalid Square JSON fails
the read rather than becoming a successful empty response. No requests, API
versions, query permissions or credential refresh policies change.

## Alerts and progress

The hub displays in-page alerts for failed, stale, delayed and stalled reads.
Acquisition grace windows retain the existing source freshness conventions:
60 minutes for catalog, C-Trax stock/sales and SwipeSimple, ten minutes for
Authorize.net reporting, 36 hours for NAB/IRIS and eight hours for backups.
These are operational grace periods, not vendor delivery guarantees. Queued
work older than 15 minutes without a scheduled execution needs review; running
work older than 45 minutes is stalled. Neither observation cancels or retries a
job. An operator must inspect the actual worker and recurring configuration.

Recent receipts show a recovery/failure-change transition only when observed
completed statuses/categories differ. Repeated unchanged failures do not create
new recovery claims. This hub sends no email, chat or other outbound alerts,
and opening the page creates no alert/job records. Sync runs post their own
completion and failure notices to the #announcements team chat room
([team-chat.md](team-chat.md)). Durable transition
notifications and verified financial coverage remain future work.

## Storage, permissions and rollout

`CreateSyncAttempts` is an additive metadata-only migration. Receipts contain
source/operation identifiers, status/category, local timestamps, tenant and
Active Job ID. They contain no credentials, credential fingerprints, arguments,
vendor messages, financial rows, source documents or merchant identifiers.
Existing encrypted stores and their setup versions are untouched by telemetry.
Metadata persistence uses isolated transactions; a diagnostic storage failure
logs a fixed warning and preserves the connector's original return/exception.

Existing active-workspace and `settings.read` gates apply. Platform backup
receipts use a null tenant and appear only for a fresh active platform super
administrator. Ordinary source histories are tenant scoped. The page retains
`no-store`, no-referrer and Turbo snapshot restrictions. Existing write/read
action gates remain unchanged.

The existing nightly retention job prunes this new metadata after 90 days,
including platform backup receipts separately; existing business-data retention
windows and scheduling are unchanged. Only the newest five receipts per channel
are displayed. No production receipt history is backfilled with guessed causes.

Before deployment, preserve the current combined SER8 revision, private runtime
keys/environment, encrypted credential rows and all source schedule flags. Take
a consistent private database backup; rehearse the additive migration against a
private clone and verify prior data/credential/configuration preservation. Build
assets and use the established guarded release/restart process. Confirm the hub
renders, acquisition/queue unknowns are honest, and web/jobs remain healthy.
Pushing a PR does not deploy, run a real read, rotate keys or enable a schedule.

See [the master setup workflow and improvement plan](master-credentials-and-sync.md).
