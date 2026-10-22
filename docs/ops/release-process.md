# Release process

Rupert has two distinct paths: SER8's updater can install eligible commits from
`main` according to the instance's automatic or click-only mode, while a stable
release is an explicitly tagged product milestone. A tag does not itself
promote production, and a `main` install is not stable-release or operator
acceptance. See the [development and deployment workflow](../development-and-deployment-workflow.md)
and the [SER8 updater runbook](../../deploy/ser8/README.md#auto-deploy-rupert-autodeploy).

Each PR must pass the current required checks: `CI (sqlite3)`, `Product site
consistency`, `Dependency and static scan`, and `cla`. Verify the exact
integrated SHA and applicable mobile checks before a release. The updater
currently checks only `CI (sqlite3)` at deployment time; expanding that gate is
tracked in issue #334.

## 1. Cut the release (on a laptop)

```bash
git checkout main && git pull
# bump VERSION (semver), move CHANGELOG "Unreleased" under a dated heading
git commit -am "Release v0.3.0" && git tag -a v0.3.0 -m "Rupert 0.3.0" && git push origin main v0.3.0
```

The `Release` workflow creates the GitHub release with notes from the commits. If the Shopify app configuration changed (`shopify.app.toml`), run `shopify app deploy` from the repo root with the owner's Partner account.

## 2. Promote on SER8 (inside the `rupert` Incus container)

```bash
sudo -iu rupert
cd /opt/rupert && git fetch --tags && git status --short      # must be clean; never deploy over local edits
set -a; . /etc/rupert.env; set +a                              # or run each command with the env loaded
bundle exec bin/rails runner 'puts BuildInfo.current.revision' # note the running build for rollback
sudo systemctl start rupert-backup.service                     # consistent pre-release backup
git checkout v0.3.0
cd web && bundle install --deployment --without development test
bin/rails db:migrate                                           # migrations are additive; rehearse destructive ones on a restored copy first
bin/rails tailwindcss:build && bin/rails assets:precompile && bin/rails ops:sqlite:optimize
```

Activate:

```bash
sudo systemctl reload rupert-web      # SIGUSR2: Puma re-execs with the new code without dropping connections
sudo systemctl restart rupert-jobs    # the worker must pick up new job code and recurring.yml
```

If `reload` does not change the build header (old Puma pre-dates the unit's `ExecReload`), use `sudo systemctl restart rupert-web` (a few seconds of 502 at the proxy). If AppArmor denies the signal, follow the host-side `incus restart rupert` procedure in `sqlite-incus.md`; never relax the profile.

## 3. Verify

```bash
curl -sI https://herbalhealers.rupertpos.com/up | grep -i x-rupert-build     # equals `git rev-parse v0.3.0`
curl -s  https://herbalhealers.rupertpos.com/up/ready                          # "ready" once the worker heartbeats and the next sync lands
sudo systemctl status rupert-web rupert-jobs | grep -E "Active|NRestarts"
```

Then sign in, open Dashboard, Inventory, Sales and the Sync page; wait for the next 15-minute sync to succeed. Record the tag, time and build SHA in the operator log.

## 4. Roll back

Code: `git checkout <previous tag>` in `/opt/rupert`, rebuild assets, reload/restart as above. Additive migrations can stay in place (the previous code ignores new tables/columns). A migration that changed existing columns needs its `down` rehearsed on a restored copy before rolling back, or restore the pre-release backup following the [backup runbook](backup-restore-runbook.md) — only if no business writes happened since, or with the owner's written approval of the data loss.

## Migration safety rules

- Prefer additive migrations (new tables, nullable columns, new indexes). Backfill in a separate step; drop old columns in a later release.
- Never run a migration that rewrites a large table during opening hours; SQLite holds the write lock for its duration.
- `db/schema.rb` is the single SQLite schema dump and changes with every migration; CI loads it.
- Rehearse every migration on a restored copy (`bin/restore-drill --keep`, then `RUPERT_SQLITE_DATABASE_PRODUCTION=<copy> bin/rails db:migrate`) before promoting.
