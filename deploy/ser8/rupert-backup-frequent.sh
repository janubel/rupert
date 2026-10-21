#!/usr/bin/env bash
# Frequent rolling SQLite snapshot of the live Rupert database. Runs INSIDE the SER8 "rupert" Incus container
# from rupert-backup-frequent.timer. Complements (does not replace) the 6-hourly bin/backup.sh run:
#   - its own directory, so bin/backup.sh's "keep latest 32" pruning can never eat the longer-lived dumps;
#   - tiered retention that stays bounded as the database grows: every snapshot for KEEP_ALL_MIN minutes
#     (default 120), then one per hour until RETAIN_MIN minutes (default 1440 = 24h). With a 1 GB database that is
#     about 46 copies instead of 288;
#   - a free-space guard: the snapshot is skipped, loudly, when the disk could not hold another copy plus
#     MIN_FREE_MB. A full disk would stop the live database, so a backup must never be what fills it;
#   - a status file the app shows on System → Backups (STATUS_DIR, default /opt/rupert/web/storage/backups).
#   - DB snapshot only. The .env/encryption keys are copied by bin/backup.sh and do not change between runs.
# Consistent while the app writes (VACUUM INTO), integrity-checked before it is kept.
set -euo pipefail
umask 077

for f in "${ENV_FILE:-}" /etc/rupert.env; do [ -n "$f" ] && [ -r "$f" ] && { ENV_SRC="$f"; break; }; done
: "${ENV_SRC:?no readable env file found}"
set -a
# shellcheck disable=SC1090
source "$ENV_SRC"
set +a

OUT="${OUT:-/var/backups/rupert/frequent}"
KEEP_ALL_MIN="${KEEP_ALL_MIN:-120}"
RETAIN_MIN="${RETAIN_MIN:-1440}"
MIN_FREE_MB="${MIN_FREE_MB:-5120}"
APP_DIR="${APP_DIR:-/opt/rupert}"
STATUS_DIR="${STATUS_DIR:-$APP_DIR/web/storage/backups}"
SQLITE_DB="${RUPERT_SQLITE_DATABASE_PRODUCTION:-$APP_DIR/web/storage/production.sqlite3}"
install -d -m 0700 "$OUT"

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'; }
free_bytes() { df -B1 --output=avail "$1" 2>/dev/null | tail -1 | tr -d ' '; }
# write_status STATE MESSAGE [FILE BYTES KEPT]: one small JSON per layer, replaced atomically, readable by the app.
write_status() {
  install -d -m 0755 "$STATUS_DIR" 2>/dev/null || return 0
  local tmp="$STATUS_DIR/.frequent.json.tmp"
  printf '{"layer":"frequent","state":"%s","at":"%s","message":"%s","file":"%s","bytes":%s,"kept":%s,"free_bytes":%s}\n' \
    "$1" "$(date -u +%FT%TZ)" "$(json_escape "$2")" "$(json_escape "${3:-}")" "${4:-0}" "${5:-0}" "$(free_bytes "$OUT")" > "$tmp"
  chmod 0644 "$tmp" && mv -f "$tmp" "$STATUS_DIR/frequent.json"
}
fail() { echo "$1" >&2; write_status failed "$1"; exit 1; }

# One run at a time: a slow snapshot must not stack up behind the next tick.
exec 9>"$OUT/.lock"
flock -n 9 || { echo "previous frequent backup still running; skipping" >&2; exit 0; }

# Tiered pruning first, so the space check below sees what this run will actually need.
#   newer than KEEP_ALL_MIN: keep all; older than RETAIN_MIN: delete; in between: keep the first snapshot of each hour.
find "$OUT" -maxdepth 1 -name 'rupert-*.sqlite3.gz' -mmin "+$RETAIN_MIN" -delete
last_hour=""
while IFS= read -r f; do
  hour="$(basename "$f" | sed -E 's/^rupert-([0-9]{8}-[0-9]{2}).*/\1/')"
  if [ "$hour" = "$last_hour" ]; then rm -f "$f"; else last_hour="$hour"; fi
done < <(find "$OUT" -maxdepth 1 -name 'rupert-*.sqlite3.gz' -mmin "+$KEEP_ALL_MIN" | sort)

db_bytes="$(stat -c %s "$SQLITE_DB")"
avail="$(free_bytes "$OUT")"
need=$(( db_bytes + db_bytes / 4 + MIN_FREE_MB * 1024 * 1024 ))
[ "$avail" -ge "$need" ] || fail "skipped: $(( avail / 1048576 )) MB free on $OUT, need $(( need / 1048576 )) MB (database $(( db_bytes / 1048576 )) MB + ${MIN_FREE_MB} MB headroom). Free disk space."

TS="$(date +%Y%m%d-%H%M%S)"
SNAP="$OUT/.snapshot-$TS.sqlite3"
FINAL="$OUT/rupert-$TS.sqlite3.gz"
trap 'rm -f "$SNAP" "$FINAL.partial"' EXIT

sqlite3 "$SQLITE_DB" "VACUUM INTO '$SNAP'" || fail "VACUUM INTO failed"
[ "$(sqlite3 "$SNAP" 'PRAGMA integrity_check')" = "ok" ] || fail "snapshot failed integrity_check"
gzip -c "$SNAP" > "$FINAL.partial"
mv "$FINAL.partial" "$FINAL"
chmod 0600 "$FINAL"

kept="$(find "$OUT" -maxdepth 1 -name 'rupert-*.sqlite3.gz' | wc -l)"
bytes="$(stat -c %s "$FINAL")"
write_status ok "snapshot ok; $kept kept (all for ${KEEP_ALL_MIN} min, hourly to ${RETAIN_MIN} min)" "$FINAL" "$bytes" "$kept"
echo "frequent backup ok: $FINAL ($(du -h "$FINAL" | cut -f1)); kept $kept"
