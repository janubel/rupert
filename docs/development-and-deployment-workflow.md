# Development and deployment workflow

This guide is the shared path from an issue to an accepted change. It describes
the repository and SER8 automation as audited on 2026-10-22. Repository settings
and the installed updater can change; verify current GitHub checks and operator
mode before relying on them.

## 1. Start with one work contract

Before implementation, link the work to an issue or create a focused issue. It
should state the user outcome, scope and exclusions, acceptance checks, data or
permission impact, dependencies, rollout and recovery plan, and whether live
operator acceptance is required. Give one person ownership of integration.
Check open issues, PRs and active work for overlap before opening another PR.

Keep each change on its own short-lived branch and worktree. Do not share a
mutable checkout or push to another contributor's branch. Split independent
behaviors into separately reviewable PRs and link related work. Checkpoint
locally as useful; push coherent updates because each new PR head consumes CI.

## 2. Branch and review policy

Use `main` as the integration branch and open a PR for changes. Branch names
normally use `fix/`, `feature/`, `docs/` or a contributor/tool prefix. Branches
are configured for deletion after merge.

The API-verified `main` protection snapshot on 2026-10-22 requires a PR, has
zero required approving reviews, and does not require a PR branch to be current
with `main` (`strict=false`). It requires `CI (sqlite3)`, `Product site
consistency`, `Dependency and static scan`, and `cla`. `Employee mobile` is
path-filtered and is not a required check. Treat current GitHub settings as the
source of truth; see [issue #206](https://github.com/techmore/rupert/issues/206)
for the exact-SHA release receipt and missing/skipped-check evidence that are
still open.

Fix a real merge conflict when it blocks integration. Do not rebase solely
because `main` advanced. A green PR head is necessary for merge, but does not
prove that the integrated commit is deployable or accepted by an operator.

## 3. CI and integration

Full CI runs on pull requests and on pushes to `main`; feature-branch pushes do
not launch a duplicate full CI run. Mobile checks remain path-filtered. The
security workflow runs for pull requests, `main` pushes and its scheduled
scans. Cancellation should supersede older runs for the same PR, not serialize
unrelated work. Keep required check names stable and do not let path filters
silently skip a required check.

After a merge, verify the checks for the exact integrated `main` SHA. Preserve
the links to required runs and any applicable mobile validation with the PR or
release record. A successful check on an earlier or duplicate event is not a
substitute for a failed required check on the current head. The deployment
updater currently gates on the newest `CI (sqlite3)` check for the target SHA;
requiring the product-site and security checks at deploy time remains an
implementation decision tracked in [issue #334](https://github.com/techmore/rupert/issues/334).

Measure CI cost with runner-minute billing data and comparable windows. Record
runner minutes, runs per unique PR SHA, duplicate event pairs, queue time,
cancellations, failures and median completion time. Workflow counts alone do
not establish savings.

## 4. Deployment modes and release boundaries

SER8 runs the Rails application in Incus. The `rupert-autodeploy` timer polls
`origin/main` every five minutes. When the in-app updater is in **Automatically**
mode, a green eligible `main` commit can install without a stable release tag.
In **Only when I click Install** mode, an operator request is required. The
installed mode and deployed SHA must be verified from the host/app status; do
not infer either from repository configuration.

The updater checks for a clean checkout and fast-forward, waits for the newest
`CI (sqlite3)` check on the target SHA, takes a pre-deploy SQLite backup, installs
dependencies, migrates and precompiles assets, restarts services, then checks
`/up`. On health-check failure it rolls back the code; it does not reverse
database migrations. It records a failed SHA to avoid retry loops. A manual
request can retry a failed SHA. See the [SER8 updater runbook](../deploy/ser8/README.md#auto-deploy-rupert-autodeploy)
for file state, commands and limitations.

A stable `v*` tag/release, an automatic `main` install, a successful `/up`, and
product/operator acceptance are separate events. A release must target the
intended exact commit and include its checks and reviewed notes. Do not claim a
feature is live from a merge or prerelease alone; verify `X-Rupert-Build` and
the rendered feature on the intended instance.

## 5. Deployment receipt and recovery

For each release or operationally accepted change, record privately:

- PR URL, integrated full SHA, relevant exact-SHA check URLs and release/tag;
- deploy mode and observed current/target SHA, with the time of verification;
- backup identifier, migration/build outcome, service restart and health result;
- rollback result or reason it was not needed, plus operator acceptance and
  limitations.

Never put credentials, customer records, private logs or recovery material in
public GitHub. Keep deployments, merchant/provider writes, payroll actions and
restore decisions within their existing owner/operator authorization boundary.

Prefer additive migrations and rehearse recovery on an isolated restored copy.
The updater can roll back application code after a health failure, but database
migrations remain. Restoring a backup after business writes can lose data and
requires the owner's written approval. Follow the
[backup and restore runbook](ops/backup-restore-runbook.md).

## 6. Acceptance and evidence

Track the change through distinct states: PR checks, merged SHA, integrated
checks, deploy eligibility, backup, migration/build, installed revision,
health, publication and operator acceptance. Close an implementation issue
when its code and repository-level acceptance criteria are complete. Keep
issues open when they still require production evidence, finance reconciliation,
merchant use, owner/operator review, or recovery acceptance. Record the exact
remaining evidence without exposing private business data.

Related gates: [deployment readiness #207](https://github.com/techmore/rupert/issues/207),
[release readiness #326](https://github.com/techmore/rupert/issues/326), and
[workflow/deployment gates #334](https://github.com/techmore/rupert/issues/334).
