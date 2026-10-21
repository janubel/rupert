#!/usr/bin/env bash
# Weekly restore drill for Rupert's encrypted off-host backups. Runs on the SER8 HOST as the same user as
# rupert-offhost-backup.sh. A backup that was never restored is a hope, not a backup: this decrypts the newest set
# into memory-backed temp space (never the disk), gunzips it, runs SQLite integrity and foreign-key checks, counts
# the business tables (with python3's sqlite3 module; the host has no sqlite3 CLI) and checks the settings dump and env copy decrypt. Result goes to System → Backups
# (layer "verify") and to the journal. Nothing touches the live database or the container's files.
#
#   install -Dm755 deploy/ser8/rupert-backup-verify.sh ~/.local/bin/rupert-backup-verify.sh
#   install -Dm644 deploy/ser8/rupert-backup-verify.service deploy/ser8/rupert-backup-verify.timer -t ~/.config/systemd/user/
#   systemctl --user daemon-reload && systemctl --user enable --now rupert-backup-verify.timer
set -euo pipefail
umask 077

OUT="${OUT:-$HOME/backups/rupert}"
KEY_FILE="${KEY_FILE:-$HOME/.config/rupert/offhost.key}"
INSTANCE="${INSTANCE:-rupert}"
STATUS_PATH="${STATUS_PATH:-/opt/rupert/web/storage/backups/verify.json}"
TABLES="${TABLES:-payments orders bank_statement_lines journal_lines reconciliation_documents users}"

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'; }
write_status() { # STATE MESSAGE [FILE BYTES]
  printf '{"layer":"verify","state":"%s","at":"%s","message":"%s","file":"%s","bytes":%s,"kept":0,"free_bytes":0}\n' \
    "$1" "$(date -u +%FT%TZ)" "$(json_escape "$2")" "$(json_escape "${3:-}")" "${4:-0}" \
    | incus file push --mode 0644 --uid 0 --gid 0 --create-dirs - "$INSTANCE$STATUS_PATH" 2>/dev/null || true
}
fail() { echo "$1" >&2; write_status failed "$1" "${ENC:-}"; exit 1; }

[ -r "$KEY_FILE" ] || fail "encryption key $KEY_FILE is missing or unreadable"
ENC=$(ls -1t "$OUT"/rupert-sqlite-*.sql.gz.enc 2>/dev/null | head -1)
[ -n "$ENC" ] || fail "no encrypted backup found in $OUT"
stamp="${ENC##*/rupert-sqlite-}"; stamp="${stamp%%.sql.gz.enc}"
age_h=$(( ( $(date +%s) - $(stat -c %Y "$ENC") ) / 3600 ))

# Memory-backed scratch space so decrypted data never lands on disk; fall back to a private tmp dir if it is too small.
need=$(( $(stat -c %s "$ENC") * 6 ))
if [ "$(df -B1 --output=avail /dev/shm 2>/dev/null | tail -1 | tr -d ' ')" -ge "$need" ]; then
  WORK=$(mktemp -d -p /dev/shm rupert-verify.XXXXXX)
else
  WORK=$(mktemp -d rupert-verify.XXXXXX)
fi
trap 'rm -rf "$WORK"' EXIT

# Stored-bytes check first: the ciphertext digest written at backup time.
( cd "$OUT" && sha256sum -c --quiet "$(basename "$ENC").sha256" ) || fail "ciphertext digest mismatch for $ENC"

openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:$KEY_FILE" -in "$ENC" | gunzip -c > "$WORK/restored.sqlite3" || fail "could not decrypt or decompress $ENC"

# The host has python3 but no sqlite3 CLI; python's sqlite3 module runs the same PRAGMAs.
# Prints "ok <fk-problem-count> table=count ..." or the integrity_check text on failure.
checks=$(python3 - "$WORK/restored.sqlite3" $TABLES <<'PYEOF'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
integrity = db.execute("PRAGMA integrity_check").fetchone()[0]
if integrity != "ok":
    print(integrity); sys.exit(2)
fk = len(db.execute("PRAGMA foreign_key_check").fetchall())
counts = []
for table in sys.argv[2:]:
    try:
        counts.append(f"{table}={db.execute(f'SELECT COUNT(*) FROM \"{table}\"').fetchone()[0]}")
    except sqlite3.Error:
        print(f"table {table} missing"); sys.exit(3)
print("ok", fk, *counts)
PYEOF
) || fail "restored copy of $ENC failed: ${checks:-sqlite check error}"
read -r _ fk counts <<<"$checks"
[ "$fk" -eq 0 ] || fail "foreign_key_check reported $fk problem rows on restored copy of $ENC"
case " $counts " in *" users=0 "*) fail "restored copy has no users";; esac

for side in "settings-$stamp.sql.enc" "env-sqlite-$stamp.enc"; do
  [ -f "$OUT/$side" ] || fail "sidecar $side missing"
  openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:$KEY_FILE" -in "$OUT/$side" > "$WORK/side" || fail "could not decrypt $side"
  [ -s "$WORK/side" ] || fail "$side decrypted to an empty file"
done
grep -q '^RAILS_ENCRYPTION_PRIMARY_KEY=' "$WORK/side" || fail "env copy has no RAILS_ENCRYPTION_PRIMARY_KEY; settings could not be decrypted after a restore"

msg="restore drill ok on set $stamp (${age_h}h old): integrity ok, no FK errors; $counts"
write_status ok "$msg" "$ENC" "$(stat -c %s "$ENC")"
echo "$msg"
