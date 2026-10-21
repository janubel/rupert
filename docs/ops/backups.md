# Rupert backups: what exists, what each layer is for, how to restore

Rupert runs on one SQLite file (`/opt/rupert/web/storage/production.sqlite3`) inside the `rupert` Incus container on
SER8. Uploaded statements, exports and receipts are stored inside that file too (base64 in `reconciliation_documents`
and `purchase_receipts`), so one file holds everything a restore needs except the encryption keys in `/etc/rupert.env`
and the settings dump. Every layer below copies that one file.

**System → Backups** (super admins with `system.read`) shows each layer's last report. Each script writes a small JSON
file to `storage/backups/<layer>.json` after every run (`state` ok/failed, `at`, `message`, `file`, `bytes`, `kept`,
`free_bytes`); the app only reads them. A layer that has not reported inside its usual interval shows **Overdue**; one
that has never reported shows **Not reporting**, which means it is not installed on this server. The MCP tool
`backup_freshness` reports the same layers to connected assistants.

## The layers

| Layer | Where it runs | How often | Keeps | Protects against | Script / unit |
| --- | --- | --- | --- | --- | --- |
| Rolling snapshot (`frequent`) | container, root | every 5 min | all for 2 h, then hourly to 24 h | the last day of mistakes: a bad import, a deleted record, a bad migration | `deploy/ser8/rupert-backup-frequent.sh`, `.timer` |
| Local backup set (`local`) | container, root | every 6 h | 32 sets (~8 days) | needing database + settings dump + `.env` together | `bin/backup.sh`, `deploy/rupert-backup-ser8.*` |
| Encrypted copy outside the container (`offhost`) | SER8 host, user timer | every 6 h | 35 sets | loss or corruption of the container | `deploy/ser8/rupert-offhost-backup.sh`, `.timer` |
| Mirror on another machine (`offsite`) | a second computer, user timer | every 6 h while that machine is on | 14 sets (and a cloud bucket when `RCLONE_REMOTE` is set) | loss of the SER8 disk, the host or the building | `deploy/offsite/rupert-backup-mirror.sh`, `.timer` |
| Restore drill (`verify`) | SER8 host, user timer | weekly (Sunday 04:30) | nothing; decrypts into memory | backups that cannot be restored | `deploy/ser8/rupert-backup-verify.sh`, `.timer` |
| Auto-deploy pre-deploy copy | container, root | before each deploy | last 5 | a bad release | `deploy/ser8/rupert-autodeploy.sh` |
| Google Drive (`BackupJob`) | app | every 6 h, when connected | 7 | off-site copy without a second machine | Settings → Backup. **Not connected**: the OAuth app is in Testing (see `google-backup-verification.md`). |

Every copy except the mirror lives on SER8's single NVMe disk. The mirror is what survives that disk. Until the mirror
or Drive is running, a lost SER8 means a lost database.

### Growth and disk space

Each snapshot is a full copy (SQLite `VACUUM INTO`), so backup space grows with the database times the number kept.
The rolling snapshot therefore thins to hourly after two hours (about 46 copies a day instead of 288). Every script
refuses to run, and reports **Failed** with the reason, when the target disk would drop under `MIN_FREE_MB` (5 GB on
SER8, 2 GB on the mirror): a backup must never be what fills the disk, because a full disk stops the live database.
If System → Backups shows "skipped: … MB free", free disk space first; the next tick resumes by itself.

Ad-hoc copies taken by hand during deployments live under `/var/backups/rupert/<name>/` in the container and are not
pruned by anything. Review and delete them when the disk is tight (`du -sh /var/backups/rupert/* | sort -h`).

## Install

Inside the container (as root), after merging a change to the scripts:

```sh
cd /opt/rupert
install -m 0755 deploy/ser8/rupert-backup-frequent.sh /usr/local/sbin/
install -m 0644 deploy/ser8/rupert-backup-frequent.service deploy/ser8/rupert-backup-frequent.timer /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now rupert-backup-frequent.timer rupert-backup.timer
systemctl start rupert-backup.service   # bin/backup.sh runs from the checkout; the deployer keeps it current
```

On the SER8 host (as the normal user; `loginctl enable-linger $USER` once):

```sh
install -Dm755 deploy/ser8/rupert-offhost-backup.sh ~/.local/bin/rupert-offhost-backup.sh
install -Dm755 deploy/ser8/rupert-backup-verify.sh ~/.local/bin/rupert-backup-verify.sh
install -Dm644 deploy/ser8/rupert-offhost-backup.service deploy/ser8/rupert-offhost-backup.timer \
  deploy/ser8/rupert-backup-verify.service deploy/ser8/rupert-backup-verify.timer -t ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now rupert-offhost-backup.timer rupert-backup-verify.timer
```

The off-host key: `~/.config/rupert/offhost.key` (mode 0600), created once with `openssl rand -base64 48`, and a copy
in the password manager. Without it the `.enc` files are unreadable.

On the mirror machine (any Linux box with `rsync`, `ssh sdolbec-ser8` working in BatchMode, and linger enabled):

```sh
install -Dm755 deploy/offsite/rupert-backup-mirror.sh ~/.local/bin/rupert-backup-mirror.sh
install -Dm644 deploy/offsite/rupert-backup-mirror.service deploy/offsite/rupert-backup-mirror.timer -t ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now rupert-backup-mirror.timer
```

Settings live in the unit's environment (`systemctl --user edit rupert-backup-mirror.service`): `SSH_HOST`, `OUT`,
`KEEP`, `MIN_FREE_MB`, and `RCLONE_REMOTE` for a cloud copy (`rclone config` first, e.g. a Backblaze B2 or S3 bucket;
the mirror then runs `rclone sync` of the encrypted files after each pull). The mirror only ever holds ciphertext and
digests; the key stays on SER8 and in the password manager.

## Restore

Never restore over the live database as a test. Restore to a copy, check it, then plan a maintenance window.

1. Pick a set. Local: `/var/backups/rupert/rupert-<stamp>.sql.gz` (a gzipped SQLite file despite the name) with
   `settings-<stamp>.sql` and `env-<stamp>`. Off-host or mirror: the same three as `.enc` files.
2. Decrypt if needed (host or mirror, with the key):
   ```sh
   openssl enc -d -aes-256-cbc -pbkdf2 -pass file:$HOME/.config/rupert/offhost.key -in rupert-sqlite-<stamp>.sql.gz.enc | gunzip -c > restored.sqlite3
   openssl enc -d -aes-256-cbc -pbkdf2 -pass file:$HOME/.config/rupert/offhost.key -in env-sqlite-<stamp>.enc > restored.env
   ```
   Compare `sha256sum restored.sqlite3` with the `.plain.sha256` sidecar (it is the digest of the compressed file, so
   check `openssl enc -d … | sha256sum` instead for an exact match).
3. Check it: `sqlite3 restored.sqlite3 'PRAGMA integrity_check; PRAGMA foreign_key_check; SELECT COUNT(*) FROM payments;'`
   (this is exactly what the weekly drill does).
4. Maintenance window, inside the container: `systemctl stop rupert-web rupert-jobs`, move the live
   `production.sqlite3`, `-wal` and `-shm` aside, copy `restored.sqlite3` to `/opt/rupert/web/storage/production.sqlite3`
   (`chown rupert:rupert`, mode 0600), make sure `/etc/rupert.env` has the same `RAILS_ENCRYPTION_*` keys as the
   backup's env copy (encrypted settings and bank descriptions are unreadable otherwise), then
   `systemctl start rupert-web rupert-jobs` and check `/up` and Settings → Connections.
5. The settings dump (`settings-<stamp>.sql`, SQL INSERT statements) is only needed if the settings table alone has to
   be rebuilt; the snapshot already contains it.

## Known gaps

- Google Drive backup is configured but has never uploaded: the Google OAuth app is in Testing and the owner has not
  granted consent. Until then the mirror is the only off-site copy.
- The mirror depends on the second machine being switched on; its allowance before **Overdue** is 48 hours for that
  reason. A cloud bucket (`RCLONE_REMOTE`) removes that dependency.
- SER8's disk was at 91% on 2026-10-21 with about 30 GB of backups in the container, about 20 GB of them ad-hoc
  copies from earlier deployments. See "Growth and disk space".
