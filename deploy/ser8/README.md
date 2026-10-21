# SER8 host-side watcher

`rupert-sync-watch` runs on the SER8 **host** as a user timer (every 15 minutes) and fails when Rupert's newest
successful sync is older than 45 minutes or `rupert-jobs` is not active. A failed run is visible in Cockpit and in
`systemctl --user --failed`. It is read-only: it never restarts anything.

It lives outside the container on purpose: the in-app monitors run on the same job worker, so they cannot report it
being down. That worker was down from 2026-10-02 to 2026-10-13 and nobody noticed.

Install (lingering must be on: `loginctl enable-linger $USER`):

```sh
install -Dm755 deploy/ser8/rupert-sync-watch.sh ~/.local/bin/rupert-sync-watch.sh
install -Dm644 deploy/ser8/rupert-sync-watch.service deploy/ser8/rupert-sync-watch.timer -t ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now rupert-sync-watch.timer
```

Check by hand: `~/.local/bin/rupert-sync-watch.sh` (exit 0 = fresh). `MAX_AGE_MIN=0` forces a failure to test alerting.

## Auto-deploy (`rupert-autodeploy`)

Runs **inside the `rupert` Incus container** as root. Every 5 minutes it fetches `origin/main` and deploys it to
`/opt/rupert` only when all of these hold: the move is a fast-forward, the checkout is clean, and the `CI (sqlite3)`
check is green for that commit (read from the public GitHub API, no token; for a re-run job
only its latest run counts).

Each deploy takes a SQLite backup first (last 5 kept in `/var/backups/rupert-autodeploy`), then runs `bundle install`,
`db:migrate` and `assets:precompile`, restarts `rupert-web` and `rupert-jobs`, and checks `/up`. If the health check
fails it rolls the code back to the previous commit and restarts; **database migrations are not reverted**, so
migrations must stay backward compatible (the log says how many new migrations the commit carried and names the
pre-deploy backup). A commit that failed is recorded in `/var/lib/rupert-autodeploy/failed-sha` and is not retried
until `main` moves on, so a broken release does not restart the app every 5 minutes; delete that file to retry. A running scheduled job is interrupted by the restart. It does not take the
shared manual-deploy lock, so avoid deploying by hand at the same moment.

```sh
install -m755 deploy/ser8/rupert-autodeploy.sh /usr/local/sbin/
install -m644 deploy/ser8/rupert-autodeploy.service deploy/ser8/rupert-autodeploy.timer /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now rupert-autodeploy.timer
```

Check by hand: `DRY_RUN=1 /usr/local/sbin/rupert-autodeploy.sh`. Logs: `journalctl -u rupert-autodeploy`.
Stop it with `systemctl disable --now rupert-autodeploy.timer`.

When updating an installed watcher, replace the copied `/usr/local/sbin/rupert-autodeploy.sh` with the current repository version before re-enabling the timer. Older copies may still require the retired PostgreSQL CI check and otherwise keep deployments blocked. The source script now gates on `CI (sqlite3)` only.
