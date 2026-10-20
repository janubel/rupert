#!/usr/bin/env bash
# Off-host copy of Rupert's SQLite backups, encrypted. Runs on the SER8 HOST (not inside the container) from a user
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
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

[ -r "$KEY_FILE" ] || { echo "refusing to run: encryption key $KEY_FILE is missing or unreadable (see setup in this script)" >&2; exit 2; }
[ "$(stat -c %a "$KEY_FILE")" = "600" ] || { echo "refusing to run: $KEY_FILE must be mode 0600" >&2; exit 2; }
install -d -m 0700 "$OUT"

# Take a fresh consistent snapshot inside the container, then pull the newest set out.
incus exec "$INSTANCE" -- systemctl start rupert-backup.service
newest() { incus exec "$INSTANCE" -- sh -c "ls -1t /var/backups/rupert/$1 | head -1"; }
DB_SRC=$(newest 'rupert-*.sql.gz'); SET_SRC=$(newest 'settings-*.sql'); ENV_SRC=$(newest 'env-*')

encrypt_from_container() { # $1 = path inside container, $2 = destination .enc on the host
  local src="$1" dest="$2" expected actual
  expected=$(incus exec "$INSTANCE" -- sha256sum "$src" | cut -d' ' -f1)
  incus exec "$INSTANCE" -- cat "$src" | openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:$KEY_FILE" -out "$dest.partial"
  # Verify: decrypt the ciphertext and compare with the source digest (the plaintext is never written to disk).
  actual=$(openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:$KEY_FILE" -in "$dest.partial" | sha256sum | cut -d' ' -f1)
  [ "$expected" = "$actual" ] || { echo "verification failed for $src" >&2; rm -f "$dest.partial"; exit 1; }
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
echo "backup ok: $OUT/rupert-sqlite-$STAMP.sql.gz.enc ($(du -h "$OUT/rupert-sqlite-$STAMP.sql.gz.enc" | cut -f1)); $(ls -1 "$OUT"/rupert-sqlite-*.sql.gz.enc | wc -l) sets kept"
