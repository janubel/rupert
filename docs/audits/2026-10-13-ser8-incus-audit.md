# SER8 Incus audit — 2026-10-13

Read-only survey of the SER8 host (Incus 6.0.5, kernel 7.0.0-34) and its 12
instances, reached over Tailscale. Nothing was changed on the host. Tailnet-only
listeners (Incus API on :8443, SSH) are not treated as exposure; the concern is
what is bound to the LAN address or `0.0.0.0`.

## Instance map

| Instance | App / repo | Autostart | Prior audit |
| --- | --- | --- | --- |
| daedalus-prod, daedalus-scanner-linux | tm-daedalus | yes | COMPLETION-AUDIT-20261008 |
| energy-monitor | Emporia-Vue3 | yes | AUDIT.md (10/4, 10/8) |
| swartzit | swartzit (SQLite) | **no** | audit-2026-09-29 (focused) |
| swartzit-db | obsolete (app uses SQLite) | no, stopped | — |
| rupert | rupert (SQLite since 2026-10-13) | **no** | this doc |
| rupert-db | obsolete Postgres | **no** | this doc |
| sonder | TM-Sonder | **no** | this doc |
| haven, homeboard, pin-telemetry, tmrootgw | no repo identified | **no** | this doc |

## Findings

1. **Reboot recovery.** Only 3 of 12 instances have `boot.autostart=true`; the
   host also has `/var/run/reboot-required` and 31 pending upgrades. A reboot
   leaves rupert, sonder, swartzit, haven, homeboard, pin-telemetry and tmrootgw
   down.
2. **homeboard auth is open to any Google account.** The oauth2-proxy config
   (`/etc/homeboard/oauth2-proxy.cfg`) sets `email_domains = ["*"]` with no
   allow-list, fronting `tasks.stoverparc.org`. `energy-monitor` by contrast
   restricts by domain plus `authenticated_emails_file`. Restrict homeboard the
   same way, or confirm `server.py` rejects unknown `X-Forwarded-Email` values.
   The `/board/api/v1/native/*` route skips auth by design and relies on a bearer
   token.
3. **pin-telemetry MQTT is anonymous on the LAN.** mosquitto has
   `allow_anonymous true`, published on `0.0.0.0:1883` (and dashboard `:8080`)
   by Incus proxy devices.
4. **tmrootgw is privileged** (`security.privileged`, `security.nesting`) with
   the host `/`, `/proc`, `/run` and `/sys` mounted. It is idle (no listeners,
   no cron, no app) — remove it, or document its purpose.
5. **Backups.** The Incus-level timers `incus-backup.timer` and
   `incus-backup-first.timer` are scheduled but their unit files do not exist,
   so they have never run. No snapshot schedules are set; the only snapshots are
   one each on rupert and daedalus-scanner-linux. The `dir` storage pool gives no
   copy-on-write snapshots. Nothing backs up sonder, haven, homeboard,
   pin-telemetry or tmrootgw at the container level.
6. **rupert backups cover the wrong database off-host.** `rupert` runs on SQLite
   (`RUPERT_DB_ADAPTER=sqlite3`, 28 MB `production.sqlite3` written today) and
   `rupert-db` has no application connections. The in-container
   `rupert-backup.timer` (every 6 h, `bin/backup.sh`) handles SQLite, but its
   output stays inside the same container. The host cron job
   (`~/.local/bin/rupert-backup`, 07:17) still `pg_dump`s `rupert-db`, so the
   off-container copies in `~/backups/rupert` are stale Postgres data. Point the
   host job at the container's `/var/backups/rupert` output, then retire
   `rupert-db`.
7. **Secrets hygiene.** `/etc/rupert.env` in the rupert container still carries
   the old Postgres host and a plaintext password. Remove or rotate it when
   `rupert-db` is retired.
8. **Service hardening** (`systemd-analyze security`): pin-telemetry services
   9.6 and rupert 9.2 (UNSAFE); swartzit 8.3 and energy-monitor 8.4 (EXPOSED);
   daedalus 7.2 and homeboard 7.1 (MEDIUM); sonder 4.5 (OK).
9. **Host-level items.** The mtg-board-layout Vite preview (`0.0.0.0:4173`) and
   game server (`*:2567`) run on the host as the admin user, as do two
   self-hosted GitHub Actions runners (TM-Sonder, swartzit); CI jobs execute on
   the machine that holds the production containers. The `dir` pool,
   `logrotate.service` failing in rupert, two pending security upgrades in
   swartzit and energy-monitor, and `unattended-upgrades` enabled only in
   daedalus-prod are smaller items. pin-telemetry and tmrootgw have no CPU or
   memory limits.

## Suggested order

1. Set `boot.autostart=true` on every instance that should come back.
2. Restrict homeboard's oauth2-proxy allow-list.
3. Repoint the host rupert backup at the SQLite output; then retire
   `rupert-db` and `swartzit-db`.
4. Add authentication to the MQTT broker or stop publishing it on the LAN.
5. Remove or document `tmrootgw`; schedule real Incus snapshots/exports and
   delete the dangling `incus-backup*` timers.
6. Reboot after upgrades once autostart is confirmed.

## Applied 2026-10-13

- `boot.autostart=true` set on rupert, sonder, swartzit, haven, homeboard and
  pin-telemetry (rupert-db, swartzit-db and tmrootgw deliberately left off).
- Host `~/.local/bin/rupert-backup` replaced with `deploy/ser8/rupert-offhost-backup.sh`
  (pulls the in-container SQLite dump, settings and env off-container, verifies
  gzip, writes a sha256). The previous script is kept as `rupert-backup.pre-sqlite`.
  First run succeeded (5.9 MB dump).

Still open (blocked or need an owner decision): stop/retire `rupert-db` and
`swartzit-db`, homeboard allow-list, MQTT auth, tmrootgw removal, pending apt
upgrades and reboot, dangling `incus-backup*` timers (need root).
