# Backup and restore runbook

Rupert's system of record on SER8 is one SQLite file: `/opt/rupert/web/storage/production.sqlite3` (plus its `-wal`/`-shm` siblings). Everything a restore needs is that file **and the encryption keys** in `/etc/rupert.env` (`RAILS_ENCRYPTION_*`, `SECRET_KEY_BASE`): without the keys, every encrypted column (credentials, documents, notes) is unreadable.

## Recovery objectives

| Layer | What | Where | Cadence | RPO it gives |
| --- | --- | --- | --- | --- |
| Rolling local snapshots | `deploy/ser8/rupert-backup-frequent.sh` (VACUUM INTO + integrity_check + gzip) | `/var/backups/rupert/frequent/` inside the container, 24 h age-based retention | every 5 min | **5 minutes** against application mistakes (bad import, wrong bulk edit) |
| Full local sets | `bin/backup.sh`: DB snapshot + `settings` table dump + copy of `/etc/rupert.env` | `/var/backups/rupert/`, newest 32 sets (~8 days) | every 6 h | 6 hours, and the keys travel with the data |
| Encrypted off-host | `deploy/ser8/rupert-offhost-backup.sh` on the SER8 **host**: pulls the newest full set out of the container, AES-256-CBC encrypts, verifies, keeps 35 sets | `$OUT` on the host (default `~/backups/rupert`); copy that directory to a second machine or object storage | every 6 h | **6 hours** against loss of the container or its disk |
| Google Drive | `BackupJob` (in-app, 7 snapshots) | owner's Drive | every 6 h when connected | not yet connected (see Needs owner in the audit) |

**RTO**: `web/bin/restore-drill` measures it for the real file. On a 2 MB test database the whole snapshot+restore took under a second; on the production file expect the drill to report seconds to low minutes. Budget **30 minutes** end to end including stopping services, copying, verifying and restarting, and **2 hours** if the container itself must be recreated.

## Drill (do this monthly and after every schema change)

Run inside the container as the app user, against the live file (read-only; nothing is written to it):

```bash
cd /opt/rupert/web && bundle exec bin/restore-drill --source /opt/rupert/web/storage/production.sqlite3
```

It prints the snapshot time, archive size, restore time, `integrity_check`, `foreign_key_check` and a per-table row-count comparison, then `DRILL OK <stamp>`. Record the stamp and the measured times in the operator log. A non-zero exit is a backup emergency: fix it before anything else.

For the off-host set, verify as stored and after decrypting:

```bash
cd ~/backups/rupert && sha256sum -c rupert-sqlite-<stamp>.sql.gz.enc.sha256
openssl enc -d -aes-256-cbc -pbkdf2 -pass file:$HOME/.config/rupert/offhost.key -in rupert-sqlite-<stamp>.sql.gz.enc | sha256sum   # compare with .plain.sha256
```

## Off-host key provisioning (once, on the SER8 host)

```bash
install -d -m 0700 ~/.config/rupert
openssl rand -base64 48 > ~/.config/rupert/offhost.key && chmod 0600 ~/.config/rupert/offhost.key
install -Dm755 deploy/ser8/rupert-offhost-backup.sh ~/.local/bin/rupert-offhost-backup.sh
install -Dm644 deploy/ser8/rupert-offhost-backup.service deploy/ser8/rupert-offhost-backup.timer -t ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now rupert-offhost-backup.timer
```

Put a copy of `offhost.key` in the password manager. The script refuses to run without the key and without mode 0600 on it. Then copy `~/backups/rupert` somewhere that is not SER8 (rsync to another machine, or `rclone` to object storage); the files are already encrypted.

## Restore procedure

Never restore an older database over newer transactions as a test. A restore is for a lost or corrupt database, or a deliberate roll-back the owner has approved in writing.

1. **Stop writers** inside the container: `systemctl stop rupert-jobs rupert-web`. Confirm nothing holds the file: `fuser /opt/rupert/web/storage/production.sqlite3` prints nothing.
2. **Preserve the current file** even if it looks broken: `cp -a production.sqlite3 production.sqlite3.broken-$(date +%s)` (and `-wal`/`-shm` if present).
3. **Pick the backup.** Newest rolling snapshot for an application mistake (`/var/backups/rupert/frequent/`), newest full set for disk loss (`/var/backups/rupert/` or the decrypted off-host copy). For off-host: `openssl enc -d -aes-256-cbc -pbkdf2 -pass file:... -in rupert-sqlite-<stamp>.sql.gz.enc > rupert-<stamp>.sql.gz`.
4. **Restore to a new file, never in place**: `gunzip -c rupert-<stamp>.sql.gz > production.restored.sqlite3`.
5. **Verify**: `sqlite3 production.restored.sqlite3 'PRAGMA integrity_check; PRAGMA foreign_key_check;'` must print `ok` and nothing else. Compare row counts of `orders`, `customers`, `ShopifyVariant`, `settings` with the operator log or the drill output.
6. **Keys**: if `/etc/rupert.env` was lost too, restore it from the `env-<stamp>` file of the same set (off-host: `env-sqlite-<stamp>.enc`). The `RAILS_ENCRYPTION_*` values must be the originals; new keys cannot read old ciphertext.
7. **Swap**: `mv production.restored.sqlite3 production.sqlite3 && rm -f production.sqlite3-wal production.sqlite3-shm && chown rupert:rupert production.sqlite3`.
8. **Start** `systemctl start rupert-web rupert-jobs`, then check `curl -s https://rupert.stoverparc.org/up/ready` (expect `"status":"ready"` once the worker heartbeat and the next sync land, within 15 minutes), sign in, open Inventory and Sales for today.
9. **Re-sync**: run a full sync from the Sync page. The mirror is idempotent; the watermark re-reads the last 48 hours of orders plus whatever was lost.
10. **Record** what was restored, from which stamp, the data gap (RPO actually incurred) and the elapsed time (RTO actually achieved).

PostgreSQL copies from before the October 2026 cutover are frozen history and are not a restore source; the application can no longer read them.

## Keys and rotation

`RAILS_ENCRYPTION_PRIMARY_KEY`, `RAILS_ENCRYPTION_DETERMINISTIC_KEY` and `RAILS_ENCRYPTION_KEY_DERIVATION_SALT` must never be rotated by simply replacing them: all encrypted columns would become unreadable. Rotation means adding a new primary key in front of the old one (Rails supports a key list) and re-encrypting records; plan it with a verified backup and the drill. `SECRET_KEY_BASE` rotation only signs everyone out. See the operator runbook for the credential-rotation list.
