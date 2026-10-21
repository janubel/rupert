#!/usr/bin/env bash
# Off-host copy of Rupert's SQLite backups, encrypted. Status goes to System → Backups via incus file push. Runs on the SER8 HOST (not inside the container) from a user
# timer. Takes a fresh consistent snapshot inside the container via the existing rupert-backup.service, pulls the
# newest DB dump, settings dump and env copy out, encrypts each with AES-256-CBC (PBKDF2) using KEY_FILE, verifies the
# ciphertext decrypts back to the exact bytes, and prunes to KEEP sets. The plaintext never touches the host disk.
#
# Setup (once, on the host):
#   install -d -m 0700 ~/.config/rupert && openssl rand -base64 48 > ~/.config/rupert/offhost.key && chmod 0600 ~/.config/rupert/offhost.key
#   # Store a copy of the key in the password manager: without it the backups are unreadable.
# Restore: openssl enc -d -aes-256-cbc -pbkdf2 -pass file:$KEY_FILE -in rupert-sqlite-<stamp>.sql.gz.enc | gunzip -c > restored.sqlite3
# Verify as stored: sha256sum -c rupert-sqlite-<stamp>.sql.gz.enc.sha256 ; after decrypting compare with the .plain.sha256 digest.
set -euo pipefail
umask 077

OUT="${OUT:-$HOME/backups/rupert}"
KEY_FILE="${KEY_FILE:-$HOME/.config/rupert/offhost.key}"
INSTANCE="${INSTANCE:-rupert}"
KEEP="${KEEP:-35}"
MIN_FREE_MB="${MIN_FREE_MB:-5120}"
STATUS_PATH="${STATUS_PATH:-/opt/rupert/web/storage/backups/offhost.json}"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

# Status for System → Backups, pushed into the container (the app cannot see the host's home directory).
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'; }
free_bytes() { df -B1 --output=avail "$1" 2>/dev/null | tail -1 | tr -d ' '; }
write_status() { # STATE MESSAGE [FILE BYTES KEPT]
  printf '{"layer":"offhost","state":"%s","at":"%s","message":"%s","file":"%s","bytes":%s,"kept":%s,"free_bytes":%s}\n' \
    "$1" "$(date -u +%FT%TZ)" "$(json_escape "$2")" "$(json_escape "${3:-}")" "${4:-0}" "${5:-0}" "$(free_bytes "$OUT")" \
    | incus file push --mode 0644 --uid 0 --gid 0 --create-dirs - "$INSTANCE$STATUS_PATH" 2>/dev/null || true
}
fail() { echo "$1" >&2; write_status failed "$1"; exit 1; }

[ -r "$KEY_FILE" ] || { echo "refusing to run: encryption key $KEY_FILE is missing or unreadable (see setup in this script)" >&2; exit 2; }
[ "$(stat -c %a "$KEY_FILE")" = "600" ] || { echo "refusing to run: $KEY_FILE must be mode 0600" >&2; exit 2; }
install -d -m 0700 "$OUT"

# A backup must never be what fills the disk; refuse early and say so where the app shows it.
avail=$(free_bytes "$OUT")
[ "$avail" -ge $(( MIN_FREE_MB * 1024 * 1024 )) ] || fail "skipped: $(( avail / 1048576 )) MB free on $OUT, need ${MIN_FREE_MB} MB. Free disk space."

# Take a fresh consistent snapshot inside the container, then pull the newest set out.
incus exec "$INSTANCE" -- systemctl start rupert-backup.service || fail "rupert-backup.service failed inside the container"
newest() { incus exec "$INSTANCE" -- sh -c "ls -1t /var/backups/rupert/$1 | head -1"; }
DB_SRC=$(newest 'rupert-*.sql.gz'); SET_SRC=$(newest 'settings-*.sql'); ENV_SRC=$(newest 'env-*')

encrypt_from_container() { # $1 = path inside container, $2 = destination .enc on the host
  local src="$1" dest="$2" expected actual
  expected=$(incus exec "$INSTANCE" -- sha256sum "$src" | cut -d' ' -f1)
  incus exec "$INSTANCE" -- cat "$src" | openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:$KEY_FILE" -out "$dest.partial"
  # Verify: decrypt the ciphertext and compare with the source digest (the plaintext is never written to disk).
  actual=$(openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:$KEY_FILE" -in "$dest.partial" | sha256sum | cut -d' ' -f1)
  [ "$expected" = "$actual" ] || { rm -f "$dest.partial"; fail "verification failed for $src"; }
  mv "$dest.partial" "$dest"
  # Two sidecars: the ciphertext digest (`sha256sum -c *.sha256` checks the files as stored) and the plaintext digest
  # to compare against after decrypting (`openssl enc -d ... | sha256sum`).
  sha256sum "$dest" | sed "s|  .*/|  |" > "$dest.sha256"
  echo "$expected  $(basename "${dest%.enc}") (plaintext, after decryption)" > "$dest.plain.sha256"
  chmod 0600 "$dest" "$dest.sha256" "$dest.plain.sha256"
}

encrypt_from_container "$DB_SRC" "$OUT/rupert-sqlite-$STAMP.sql.gz.enc"
encrypt_from_container "$SET_SRC" "$OUT/settings-$STAMP.sql.enc"
encrypt_from_container "$ENV_SRC" "$OUT/env-sqlite-$STAMP.enc"

# Prune to the newest KEEP database archives and their sidecars.
mapfile -t old < <(ls -1t "$OUT"/rupert-sqlite-*.sql.gz.enc 2>/dev/null || true)
for f in "${old[@]:$KEEP}"; do
  stamp="${f##*/rupert-sqlite-}"; stamp="${stamp%%.sql.gz.enc}"
  rm -f "$f" "$f.sha256" "$f.plain.sha256" "$OUT/settings-$stamp.sql.enc" "$OUT/settings-$stamp.sql.enc".*sha256 "$OUT/env-sqlite-$stamp.enc" "$OUT/env-sqlite-$stamp.enc".*sha256
done
kept=$(ls -1 "$OUT"/rupert-sqlite-*.sql.gz.enc | wc -l)
write_status ok "encrypted copy on the SER8 host verified; $kept sets kept" "$OUT/rupert-sqlite-$STAMP.sql.gz.enc" "$(stat -c %s "$OUT/rupert-sqlite-$STAMP.sql.gz.enc")" "$kept"
echo "backup ok: $OUT/rupert-sqlite-$STAMP.sql.gz.enc ($(du -h "$OUT/rupert-sqlite-$STAMP.sql.gz.enc" | cut -f1)); $kept sets kept"
