#!/usr/bin/env bash
# Frequent rolling SQLite snapshot of the live Rupert database. Runs INSIDE the SER8 "rupert" Incus container
# from rupert-backup-frequent.timer. Complements (does not replace) the 6-hourly bin/backup.sh run:
#   - its own directory, so bin/backup.sh's "keep latest 32" pruning can never eat the longer-lived dumps;
#   - its own retention: RETAIN_MIN minutes (default 1440 = 24h), deleted by age, not count;
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
RETAIN_MIN="${RETAIN_MIN:-1440}"
SQLITE_DB="${RUPERT_SQLITE_DATABASE_PRODUCTION:-${APP_DIR:-/opt/rupert}/web/storage/production.sqlite3}"
install -d -m 0700 "$OUT"

# One run at a time: a slow snapshot must not stack up behind the next tick.
exec 9>"$OUT/.lock"
flock -n 9 || { echo "previous frequent backup still running; skipping" >&2; exit 0; }

TS="$(date +%Y%m%d-%H%M%S)"
SNAP="$OUT/.snapshot-$TS.sqlite3"
FINAL="$OUT/rupert-$TS.sqlite3.gz"
trap 'rm -f "$SNAP" "$FINAL.partial"' EXIT

sqlite3 "$SQLITE_DB" "VACUUM INTO '$SNAP'"
[ "$(sqlite3 "$SNAP" 'PRAGMA integrity_check')" = "ok" ] || { echo "snapshot failed integrity_check" >&2; exit 1; }
gzip -c "$SNAP" > "$FINAL.partial"
mv "$FINAL.partial" "$FINAL"
chmod 0600 "$FINAL"

# Age-based pruning of this directory only.
find "$OUT" -maxdepth 1 -name 'rupert-*.sqlite3.gz' -mmin "+$RETAIN_MIN" -delete

echo "frequent backup ok: $FINAL ($(du -h "$FINAL" | cut -f1)); kept $(find "$OUT" -maxdepth 1 -name 'rupert-*.sqlite3.gz' | wc -l)"
