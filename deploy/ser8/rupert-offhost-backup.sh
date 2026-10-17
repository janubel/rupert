#!/usr/bin/env bash
# Off-container copy of Rupert's SQLite backups (rupert is on SQLite; rupert-db is retired).
set -euo pipefail
umask 077
OUT=/home/sdolbec/backups/rupert
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
install -d -m 0700 "$OUT"
# Take a fresh consistent snapshot inside the container, then pull the newest set out.
incus exec rupert -- systemctl start rupert-backup.service
newest() { incus exec rupert -- sh -c "ls -1t /var/backups/rupert/$1 | head -1"; }
DB_SRC=$(newest 'rupert-*.sql.gz'); SET_SRC=$(newest 'settings-*.sql'); ENV_SRC=$(newest 'env-*')
DUMP="$OUT/rupert-sqlite-$STAMP.sql.gz"
incus exec rupert -- cat "$DB_SRC" > "$DUMP.partial"
gzip -t "$DUMP.partial"
incus exec rupert -- cat "$SET_SRC" > "$OUT/settings-$STAMP.sql"
incus exec rupert -- cat "$ENV_SRC" > "$OUT/env-sqlite-$STAMP"
mv "$DUMP.partial" "$DUMP"
sha256sum "$DUMP" > "$DUMP.sha256"
chmod 0600 "$OUT"/*"$STAMP"*
mapfile -t old < <(ls -1t "$OUT"/rupert-sqlite-*.sql.gz 2>/dev/null || true)
for f in "${old[@]:35}"; do rm -f "$f" "$f.sha256"; done
echo "backup ok: $DUMP"
