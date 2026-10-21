#!/usr/bin/env bash
# Encrypted off-container backup of the self-hosted Buzz relay (Incus container "buzz"). Runs on the SER8 HOST from a
# user timer, like rupert-offhost-backup.sh, and uses the same key file. Each run pulls out of the container:
#   * a pg_dump of the relay database (consistent),
#   * the MinIO media volume and the git-data volume (tar of the live volumes; objects are write-once),
#   * the relay secrets: /opt/buzz/.env and /root/buzz-secrets (relay key, owner key, test identities).
# Every part is encrypted with AES-256-CBC (PBKDF2) using KEY_FILE, verified by decrypting it back and comparing the
# digest, and pruned to KEEP sets. The plaintext never touches the host disk.
#
# The weekly incus-backup.timer also exports the whole container; this script is the app-consistent copy.
# Restore (database): openssl enc -d -aes-256-cbc -pbkdf2 -pass file:$KEY_FILE -in buzz-pg-<stamp>.sql.gz.enc | gunzip -c |
#   incus exec buzz -- docker exec -i buzz-prod-postgres-1 psql -U buzz -d buzz
set -euo pipefail
umask 077

OUT="${OUT:-$HOME/backups/buzz}"
KEY_FILE="${KEY_FILE:-$HOME/.config/rupert/offhost.key}"
INSTANCE="${INSTANCE:-buzz}"
KEEP="${KEEP:-35}"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

[ -r "$KEY_FILE" ] || { echo "refusing to run: encryption key $KEY_FILE is missing or unreadable (see rupert-offhost-backup.sh)" >&2; exit 2; }
[ "$(stat -c %a "$KEY_FILE")" = "600" ] || { echo "refusing to run: $KEY_FILE must be mode 0600" >&2; exit 2; }
install -d -m 0700 "$OUT"

# $1 = destination .enc, rest = command (run on the host) whose stdout is the plaintext.
encrypt_stream() {
  local dest="$1"; shift
  "$@" | openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:$KEY_FILE" -out "$dest.partial"
  # Verify: the ciphertext must decrypt to a valid gzip stream (the plaintext is never written to disk).
  openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:$KEY_FILE" -in "$dest.partial" | gzip -t
  mv "$dest.partial" "$dest"
  sha256sum "$dest" | sed "s|  .*/|  |" > "$dest.sha256"
  chmod 0600 "$dest" "$dest.sha256"
}

in_buzz() { incus exec "$INSTANCE" -- "$@"; }

encrypt_stream "$OUT/buzz-pg-$STAMP.sql.gz.enc" \
  sh -c "incus exec $INSTANCE -- docker exec buzz-prod-postgres-1 pg_dump -U buzz -d buzz | gzip -9"
encrypt_stream "$OUT/buzz-volumes-$STAMP.tar.gz.enc" \
  incus exec "$INSTANCE" -- tar -C /var/lib/docker/volumes -czf - buzz-prod_buzz-minio-data buzz-prod_buzz-git-data
encrypt_stream "$OUT/buzz-secrets-$STAMP.tar.gz.enc" \
  incus exec "$INSTANCE" -- tar -C / -czf - opt/buzz/.env opt/buzz/compose.yml root/buzz-secrets

mapfile -t old < <(ls -1t "$OUT"/buzz-pg-*.sql.gz.enc 2>/dev/null || true)
for f in "${old[@]:$KEEP}"; do
  stamp="${f##*/buzz-pg-}"; stamp="${stamp%%.sql.gz.enc}"
  rm -f "$f" "$f.sha256" "$OUT/buzz-volumes-$stamp.tar.gz.enc"* "$OUT/buzz-secrets-$stamp.tar.gz.enc"*
done
echo "backup ok: $OUT/buzz-*-$STAMP.* ($(du -ch "$OUT"/*-"$STAMP".* | tail -1 | cut -f1) total); $(ls -1 "$OUT"/buzz-pg-*.sql.gz.enc | wc -l) sets kept"
