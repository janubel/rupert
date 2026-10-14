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
