#!/usr/bin/env bash
# Rupert database backup (PostgreSQL by default; SQLite when RUPERT_DB_ADAPTER=sqlite3 in .env): snapshot the
# production database (gzip) plus a copy of
# the .env (boot keys + encryption keys) and the encrypted settings table
# (DB-managed credentials such as Square/Shopify tokens). Restoring needs all
# three: .env holds the RAILS_ENCRYPTION_* keys that decrypt the settings dump.
# Runs from a systemd timer (see deploy/rupert-backup.timer).
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
DB="${POSTGRES_DB:-rupert_production}"
install -d -m 0700 "$OUT"
chmod 0700 "$OUT"

TS="$(date +%Y%m%d-%H%M)"
DUMP="$OUT/rupert-$TS.sql.gz"   # SQLite mode: a gzipped .sqlite3 file with the same name
DUMP_TMP="$DUMP.partial"
SETTINGS_TMP="$OUT/settings-$TS.sql.partial"
ENV_TMP="$OUT/env-$TS.partial"

if [ "${RUPERT_DB_ADAPTER:-postgresql}" = "sqlite3" ]; then
  # Consistent snapshot while the app is writing (VACUUM INTO never blocks readers/writers for long).
  SQLITE_DB="${RUPERT_SQLITE_DATABASE_PRODUCTION:-${APP_DIR:-/opt/rupert}/web/storage/production.sqlite3}"
  SNAP="$OUT/.snapshot-$TS.sqlite3"
  rm -f "$SNAP"
  sqlite3 "$SQLITE_DB" "VACUUM INTO '$SNAP'"
  [ "$(sqlite3 "$SNAP" 'PRAGMA integrity_check')" = "ok" ] || { echo "snapshot failed integrity_check" >&2; rm -f "$SNAP"; exit 1; }
  gzip -c "$SNAP" > "$DUMP_TMP"
  sqlite3 "$SNAP" ".mode insert settings" "SELECT * FROM settings" > "$SETTINGS_TMP"
  rm -f "$SNAP"
else
  : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set in $ENV_SRC}"
  PGPASSWORD="$POSTGRES_PASSWORD" \
    pg_dump -h "${POSTGRES_HOST:-localhost}" -p "${POSTGRES_PORT:-5432}" \
    -U "${POSTGRES_USER:-rupert}" -d "$DB" \
    | gzip > "$DUMP_TMP"

  PGPASSWORD="$POSTGRES_PASSWORD" \
    pg_dump -h "${POSTGRES_HOST:-localhost}" -p "${POSTGRES_PORT:-5432}" \
    -U "${POSTGRES_USER:-rupert}" -d "$DB" \
    --table=settings --data-only --column-inserts > "$SETTINGS_TMP"

fi

cp "$ENV_SRC" "$ENV_TMP"
mv "$DUMP_TMP" "$DUMP"
mv "$SETTINGS_TMP" "$OUT/settings-$TS.sql"
mv "$ENV_TMP" "$OUT/env-$TS"
chmod 0600 "$DUMP" "$OUT/settings-$TS.sql" "$OUT/env-$TS"

# Prune to the latest 32 dumps (~8 days at 4x/day) and matching sidecar files.
ls -1t "$OUT"/rupert-*.sql.gz | tail -n +33 | xargs -r rm
ls -1t "$OUT"/settings-* | tail -n +33 | xargs -r rm
ls -1t "$OUT"/env-* | tail -n +33 | xargs -r rm

echo "backup ok: $DUMP ($(du -h "$DUMP" | cut -f1))"
