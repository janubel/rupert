# Branching

The `main` branch is the Ruby on Rails (ROR) app in `web/`, the production implementation and source of truth. Deployed to SER8.

## Working branches

- Cut short-lived branches and land changes through pull requests.
- Branch off `main`.
- Naming: `fix/…`, `feature/…`, `docs/…`, or a tool prefix such as `codex/…` / `claude/…`.
- Head branches are **auto-deleted on merge** (repository setting), which keeps the branch list short.

## Deploys are not merges

Production runs on SER8 in Incus and does **not** deploy from GitHub — pushing a
commit or creating a release does not deploy it. See
[Production and deployment](../README.md#production-and-deployment).
