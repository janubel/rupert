# SER8 host-side watcher

For the end-to-end branch, CI, deployment, receipt and acceptance policy, see
the [development and deployment workflow](../../docs/development-and-deployment-workflow.md).

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

## Logs (`rupert-logs`, journald caps)

Rupert logs one JSON object per line to journald. Inside the `rupert` container:

```sh
install -m755 deploy/ser8/rupert-logs /usr/local/bin/
install -Dm644 deploy/ser8/journald-rupert.conf /etc/systemd/journald.conf.d/rupert.conf
systemctl restart systemd-journald && journalctl --vacuum-size=400M
rupert-logs errors            # also: request <id>, user <id>, upload, slow, noise, tail
```

`journald-rupert.conf` makes the journal persistent and caps it (400 MB, 30 days, 2 GB kept free). See
[`docs/ops/logging.md`](../../docs/ops/logging.md). The customer provisioner (`customer_provisioner.py`) backs off to
one poll a minute while idle; `RUPERT_PROVISIONER_MAX_IDLE_SECONDS=15` keeps the old 15 s rate.

## Backups

Five layers (5-minute rolling snapshot and 6-hourly sets inside the container, an encrypted copy on the host, a mirror on
another machine and a weekly restore drill), each reporting to **System → Backups**. Scripts, units, install steps and the
restore procedure are in [docs/ops/backups.md](../../docs/ops/backups.md).

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
install -m644 deploy/ser8/rupert-autodeploy.service deploy/ser8/rupert-autodeploy.timer deploy/ser8/rupert-autodeploy.path /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now rupert-autodeploy.timer rupert-autodeploy.path
```

### Controlling it from Rupert (System → Updates)

Instance operators (super admins with `system.read`; changes also need `system.write`) see the updater's state on
**System → Updates**, can **Install update now** / **Retry update**, cancel a pending request, and switch between
**Automatically** (the default: every green `main` installs) and **Only when I click Install**. Store admins never
see these controls; they keep the read-only "Update available" banner.

The app and the updater only exchange files; the app never gets root and never runs a deploy itself:

| File | Written by | Meaning |
| --- | --- | --- |
| `/var/lib/rupert-autodeploy/status.json` | updater, every run | `state` (`up_to_date`, `ready`, `waiting_ci`, `ci_failed`, `deploying`, `deployed`, `failed`, `blocked`), message, current/target commit, mode, time |
| `/var/lib/rupert-autodeploy/last-deploy.json` | updater, after an install | `deployed` or `failed`, from/to commit, message |
| `/var/lib/rupert-autodeploy/request-handled` | updater | mtime of the last request it acted on |
| `/opt/rupert/web/storage/autodeploy/manual` | app | present = install only when asked |
| `/opt/rupert/web/storage/autodeploy/install-requested` | app | its mtime asks for an install; `rupert-autodeploy.path` starts the updater at once |

The updater only reads the presence of `manual` and the mtime (`stat`, not following symlinks) of
`install-requested`; it never opens, writes or deletes anything in the app's directory. A request still has to pass every
gate above (green CI, fast-forward, clean checkout, backup, health check). It also clears a `failed-sha`, so a
failed commit is retried once. A request is spent when the updater acts on it: after an install attempt, or
straight away when there was nothing to install, so it never approves a commit that lands later. While CI is pending
the request waits and the page offers to cancel it. The page warns when the updater has not reported for 20 minutes.
`DRY_RUN=1` writes no status. Without the updater installed (no `status.json`), the page says updates are managed
outside Rupert.

Check by hand: `DRY_RUN=1 /usr/local/sbin/rupert-autodeploy.sh`. Logs: `journalctl -u rupert-autodeploy`.
Stop it with `systemctl disable --now rupert-autodeploy.timer`.

When updating an installed watcher, replace the copied `/usr/local/sbin/rupert-autodeploy.sh` with the current repository version before re-enabling the timer. Older copies may still require the retired PostgreSQL CI check and otherwise keep deployments blocked. The source script now gates on `CI (sqlite3)` only.

## Team chat (Buzz retired)

Team chat now runs inside Rupert at `/chat`, with no relay or agent container. See
[docs/ops/team-chat.md](../../docs/ops/team-chat.md). `team-chat/setup-local-model.sh` sets up the optional local
model container.

The old Buzz relay (`buzz`) and the sandboxed `@rupert` agent (`rupert-agent`) Incus containers are no longer used.
Their files (`agent/`, `buzz/`) and runbook were removed from `main` and are kept on the `archive/buzz` branch.
After this change deploys, stop both containers (`incus stop buzz rupert-agent`) and, if it was installed, the host's
Buzz backup timer (`systemctl --user disable --now buzz-backup.timer`). Do not delete the containers yet.
