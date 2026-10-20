# Projects and Tasks readiness review — October 20, 2026

Reviewed against `a77243d7ba6601da03b2297bfecfb1fe03a43c27` on `main`.
This review covers the Projects and Tasks web module and its assignment,
authorization, tenant isolation, state transitions, and board behavior.

## Corrections

- Task assignees and project owners can be selected, changed, and cleared.
  New assignments require an active user in the same workspace. Existing
  assignments to deactivated users remain historical and can be cleared.
- Both model validations and controller lookups enforce workspace boundaries.
  A foreign or missing top-level project produces 404 instead of silently
  creating an unlinked task. Legacy foreign assignee names are not rendered.
- Read-only users cannot create, edit, delete, transition, or move work.
  Assignment itself grants no permissions. The employee workspace remains
  restricted to its existing POS and personal time-record features.
- Task edit and delete use separate forms. Project deletion returns to the
  projects index and removes its tasks through the existing association.
- State transitions reload persisted state inside a database lock before
  choosing an event. Invalid legacy assignments return validation errors when
  moved. Completion timestamps are set and cleared through the state machine.
- The browser prevents overlapping moves for the same card, restores styling
  and column counts on failure, and verifies the JSON acknowledgement. After
  a confirmed move it refreshes the page so progress, due labels, and filtered
  results reflect the saved record.
- Project boards and cross-project boards render at most 250 cards, disclose
  truncation, and link to the complete paginated list. Assignee lookups cover
  the displayed page rather than all tasks in the tenant.
- Successful project/task creation, edits, deletion, and transitions record
  actor-attributed tenant-scoped activity entries using the existing logger.
  This inherits its best-effort logging behavior; it is not an immutable ledger.
- The production image supplies throwaway values to the asset compilation
  process for required production initializers. These are not runtime defaults.
  The entrypoint uses the POSIX shell available in the Alpine base image.

## Verification

Regression coverage exercises assignment/reassignment/unassignment, inactive
and foreign account rejection, tenant isolation across every mutation endpoint,
read-only permissions, deletion, completion timestamps, stale instances, audit
attribution, invalid legacy records, and the 250-card boundary. Browser-controller
tests cover rollback, duplicate submissions, expired-login HTML responses,
read-only boards, and refresh after successful acknowledgement.

Final test totals and release checks are recorded in the pull request. Production
asset compilation also runs with placeholder credentials on the isolated review
host; it does not connect to merchant services.

## Release conditions

No database migrations or dependency changes are required by this change. Keep
the existing backup/restore and deployment procedure, retain the current source
revision for rollback, and deploy the tested commit with its compiled assets.
An application rollback does not require restoring the database; preserve newer
business writes and activity entries.

Before operational sign-off, verify the deployed revision and authenticated
project/task pages in the intended production workspace, including assignment,
completion/reopening, filters, and activity history. Check existing records for
missing or cross-workspace project/user references before clearing or correcting
them with an operator. This patch rejects unsafe references but does not rewrite
historical data automatically.

Live checks from the review host could not establish trusted HTTPS to the
documented production URL, and the documented server alias did not resolve.
These observations do not establish that the application or its own certificate
is faulty. Live release, recovery freshness, and authenticated acceptance remain
unverified until the intended environment is reachable. Local tests alone do
not constitute production sign-off.

## Employee assigned-task access follow-up

The original review above preserved the old employee boundary. This follow-up
adds a fixed `tasks.self` permission to the employee role without granting
`projects.read` or `projects.write`. Employees have a **My tasks** entry in their
staff workspace, with board and list views of tasks assigned to their user account
in their authenticated workspace. Assignment is to a Rupert user account, so a
separate HR employee record is not required to use this feature.

Employees may edit task titles and notes, and start, block, complete, reopen or
move their assigned tasks. Managers retain creation, deletion, reassignment,
project moves, priority and due-date changes. The parent project's name provides
context; project details, project-wide progress, other employees' tasks and
unassigned tasks remain unavailable. Counts, search, filters, project selectors
and pagination all use the same restricted task scope. Staff pages are not cached.

Every task mutation reloads and reauthorizes the record under a database lock.
Reassignment therefore removes access even when an employee already has a page
open or their request has loaded the old assignment. Stale broad person/role
overrides cannot expand the fixed employee role. Deactivated accounts are denied
through the existing session checks. Other staff and management permissions are
unchanged.

Regression coverage includes both workspace and assignment boundaries, invalid
legacy cross-workspace assignments, protected-field injection, list pagination,
counts and metadata, stale overrides, in-flight reassignment, audit attribution,
and existing financial/management access restrictions. A separate production-mode
synthetic smoke checks CSRF-protected login and writes with outbound TCP blocked.
No customer data or provider jobs are needed for these checks.

This follow-up requires no database migration or dependency change. Deploy its
tested revision and compiled assets using the existing backup/recovery procedure.
Implementation and test completion do not themselves deploy this follow-up; its
release status and exact validation totals are recorded in its pull request.
