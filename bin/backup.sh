#!/usr/bin/env bash
# Rupert database backup: snapshot the SQLite production database (gzip) plus a copy of
# the .env (boot keys + encryption keys) and the encrypted settings table
# (DB-managed credentials such as Square/Shopify tokens). Restoring needs all
# three: .env holds the RAILS_ENCRYPTION_* keys that decrypt the settings dump.
# Runs from a systemd timer (see deploy/rupert-backup.timer) and on demand from the
# off-host copy (deploy/ser8/rupert-offhost-backup.sh). Writes STATUS_DIR/local.json
# for System → Backups.
set -euo pipefail
umask 077

# Env file: ENV_FILE, else /etc/rupert.env (SER8), else the old droplet location.
for f in "${ENV_FILE:-}" /etc/rupert.env /root/rupert/.env; do [ -n "$f" ] && [ -r "$f" ] && { ENV_SRC="$f"; break; }; done
: "${ENV_SRC:?no readable env file found}"
set -a
# shellcheck disable=SC1090
source "$ENV_SRC"
set +a

OUT="/var/backups/rupert"
APP_DIR="${APP_DIR:-/opt/rupert}"
STATUS_DIR="${STATUS_DIR:-$APP_DIR/web/storage/backups}"
MIN_FREE_MB="${MIN_FREE_MB:-5120}"
install -d -m 0700 "$OUT"
chmod 0700 "$OUT"

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'; }
free_bytes() { df -B1 --output=avail "$1" 2>/dev/null | tail -1 | tr -d ' '; }
write_status() {
  install -d -m 0755 "$STATUS_DIR" 2>/dev/null || return 0
  local tmp="$STATUS_DIR/.local.json.tmp"
  printf '{"layer":"local","state":"%s","at":"%s","message":"%s","file":"%s","bytes":%s,"kept":%s,"free_bytes":%s}\n' \
    "$1" "$(date -u +%FT%TZ)" "$(json_escape "$2")" "$(json_escape "${3:-}")" "${4:-0}" "${5:-0}" "$(free_bytes "$OUT")" > "$tmp"
  chmod 0644 "$tmp" && mv -f "$tmp" "$STATUS_DIR/local.json"
}
fail() { echo "$1" >&2; write_status failed "$1"; exit 1; }

TS="$(date +%Y%m%d-%H%M)"
DUMP="$OUT/rupert-$TS.sql.gz"   # historical name: the file is a gzipped .sqlite3 snapshot
DUMP_TMP="$DUMP.partial"
SETTINGS_TMP="$OUT/settings-$TS.sql.partial"
ENV_TMP="$OUT/env-$TS.partial"

# Consistent snapshot while the app is writing (VACUUM INTO never blocks readers/writers for long).
SQLITE_DB="${RUPERT_SQLITE_DATABASE_PRODUCTION:-$APP_DIR/web/storage/production.sqlite3}"
SNAP="$OUT/.snapshot-$TS.sqlite3"
trap 'rm -f "$SNAP" "$DUMP_TMP" "$SETTINGS_TMP" "$ENV_TMP"' EXIT

db_bytes="$(stat -c %s "$SQLITE_DB")"
avail="$(free_bytes "$OUT")"
need=$(( db_bytes + db_bytes / 4 + MIN_FREE_MB * 1024 * 1024 ))
[ "$avail" -ge "$need" ] || fail "skipped: $(( avail / 1048576 )) MB free on $OUT, need $(( need / 1048576 )) MB. Free disk space."

rm -f "$SNAP"
sqlite3 "$SQLITE_DB" "VACUUM INTO '$SNAP'" || fail "VACUUM INTO failed"
[ "$(sqlite3 "$SNAP" 'PRAGMA integrity_check')" = "ok" ] || fail "snapshot failed integrity_check"
gzip -c "$SNAP" > "$DUMP_TMP"
sqlite3 "$SNAP" ".mode insert settings" "SELECT * FROM settings" > "$SETTINGS_TMP"
rm -f "$SNAP"

cp "$ENV_SRC" "$ENV_TMP"
mv "$DUMP_TMP" "$DUMP"
mv "$SETTINGS_TMP" "$OUT/settings-$TS.sql"
mv "$ENV_TMP" "$OUT/env-$TS"
chmod 0600 "$DUMP" "$OUT/settings-$TS.sql" "$OUT/env-$TS"

# Prune to the latest 32 dumps (~8 days at 4x/day) and matching sidecar files.
ls -1t "$OUT"/rupert-*.sql.gz | tail -n +33 | xargs -r rm
ls -1t "$OUT"/settings-* | tail -n +33 | xargs -r rm
ls -1t "$OUT"/env-* | tail -n +33 | xargs -r rm

kept="$(ls -1 "$OUT"/rupert-*.sql.gz | wc -l)"
write_status ok "database, settings and env copied; $kept sets kept" "$DUMP" "$(stat -c %s "$DUMP")" "$kept"
echo "backup ok: $DUMP ($(du -h "$DUMP" | cut -f1))"
