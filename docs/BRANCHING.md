# Branching

The `main` branch is the Ruby on Rails (ROR) app in `web/`, the production implementation and source of truth. Deployed to SER8.

## Working branches

- Cut short-lived branches and land changes through pull requests.
- Branch off `main`.
- Naming: `fix/…`, `feature/…`, `docs/…`, or a tool prefix such as `codex/…` / `claude/…`.
- Head branches are **auto-deleted on merge** (repository setting), which keeps the branch list short.

## Deployment and acceptance

SER8's updater polls `main`; eligible commits can install automatically when
the instance is in automatic mode. In click-only mode an operator must request
the install. A merge, stable release, deployment and operator acceptance are
separate states. Verify the installed mode and SHA before describing a change
as live. See the [development and deployment workflow](development-and-deployment-workflow.md)
and [SER8 updater runbook](../deploy/ser8/README.md#auto-deploy-rupert-autodeploy).
