# Branching

Rupert runs two parallel implementations while development is moving fast.

| Branch | Role |
| --- | --- |
| `main` | The Ruby on Rails (ROR) app in `web/` — the production implementation and source of truth. Deployed to SER8. |
| `rust-core` | A parallel Rust implementation in `core/` that mirrors the Rails behaviour and is being built to match, then outperform, it. Kept in step with `main`; **not** merged into `main` while daily iteration continues. |

## Working branches

- Cut short-lived branches and land changes through pull requests.
- Branch off `main` for Rails/`web/` work, or off `rust-core` for Rust/`core/` work.
- Naming: `fix/…`, `feature/…`, `docs/…`, or a tool prefix such as `codex/…` / `claude/…`.
- Head branches are **auto-deleted on merge** (repository setting), which keeps the branch list short.

## Deploys are not merges

Production runs on SER8 in Incus and does **not** deploy from GitHub — pushing a
commit or creating a release does not deploy it. See
[Production and deployment](../README.md#production-and-deployment).

## Keeping the two tracks aligned

- Functional changes start in the Rails app (`web/`) on `main`.
- The Rust track (`core/` on `rust-core`) mirrors that behaviour and records
  parity/performance notes as it goes.
- Until daily iteration on the Rails app stops, treat `main` as the reference and
  `rust-core` as the mirror.
