#!/usr/bin/env bash
# Off-machine mirror of Rupert's encrypted backups. Runs on ANOTHER computer (a laptop, a NAS, a second server) as
# a user timer and pulls the already-encrypted sets from the SER8 host over SSH (Tailscale). Every other copy of the
# database lives on SER8's one NVMe disk; this is the copy that survives that disk, the host, or the room.
#   - pulls only *.enc and *.sha256 (ciphertext and digests; the key never leaves SER8 and the password manager),
#   - verifies every pulled database archive against its stored digest before anything is pruned,
#   - keeps the newest KEEP sets (default 14) and refuses to run when the mirror disk has under MIN_FREE_MB free,
#   - optionally pushes the mirror on to a cloud bucket with rclone (RCLONE_REMOTE, e.g. "b2:rupert-backups") for a
#     third copy that is not in anyone's house,
#   - reports to System → Backups (layer "offsite") through the SER8 host.
# Restore: see docs/ops/backups.md (needs ~/.config/rupert/offhost.key from the password manager).
#
#   install -Dm755 deploy/offsite/rupert-backup-mirror.sh ~/.local/bin/rupert-backup-mirror.sh
#   install -Dm644 deploy/offsite/rupert-backup-mirror.service deploy/offsite/rupert-backup-mirror.timer -t ~/.config/systemd/user/
#   systemctl --user daemon-reload && systemctl --user enable --now rupert-backup-mirror.timer
# Needs: rsync, ssh access to SSH_HOST (BatchMode), `loginctl enable-linger` so the timer runs without a login.
set -euo pipefail
umask 077

SSH_HOST="${SSH_HOST:-sdolbec-ser8}"
SOURCE_DIR="${SOURCE_DIR:-backups/rupert}"          # relative to the SER8 user's home
OUT="${OUT:-$HOME/backups/rupert-mirror}"
KEEP="${KEEP:-14}"
MIN_FREE_MB="${MIN_FREE_MB:-2048}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
INSTANCE="${INSTANCE:-rupert}"
STATUS_PATH="${STATUS_PATH:-/opt/rupert/web/storage/backups/offsite.json}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST")

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'; }
free_bytes() { df -B1 --output=avail "$1" 2>/dev/null | tail -1 | tr -d ' '; }
write_status() { # STATE MESSAGE [FILE BYTES KEPT]
  printf '{"layer":"offsite","state":"%s","at":"%s","message":"%s","file":"%s","bytes":%s,"kept":%s,"free_bytes":%s,"host":"%s"}\n' \
    "$1" "$(date -u +%FT%TZ)" "$(json_escape "$2")" "$(json_escape "${3:-}")" "${4:-0}" "${5:-0}" "$(free_bytes "$OUT")" "$(json_escape "$(hostname)")" \
    | "${SSH[@]}" "incus file push --mode 0644 --uid 0 --gid 0 --create-dirs - '$INSTANCE$STATUS_PATH'" 2>/dev/null || true
}
fail() { echo "$1" >&2; write_status failed "$1"; exit 1; }

install -d -m 0700 "$OUT"
"${SSH[@]}" true 2>/dev/null || { echo "$SSH_HOST unreachable; will retry on the next tick" >&2; exit 0; }

avail=$(free_bytes "$OUT")
[ "$avail" -ge $(( MIN_FREE_MB * 1024 * 1024 )) ] || fail "skipped on $(hostname): $(( avail / 1048576 )) MB free on $OUT, need ${MIN_FREE_MB} MB. Free disk space on the mirror."

# Ciphertext and digests only. No --delete: pruning is by our own KEEP below, so a wiped source cannot wipe the mirror.
rsync -a --timeout=120 -e "ssh -o BatchMode=yes" \
  --include='*.enc' --include='*.sha256' --exclude='*' \
  "$SSH_HOST:$SOURCE_DIR/" "$OUT/" || fail "rsync from $SSH_HOST failed"

mapfile -t sets < <(ls -1t "$OUT"/rupert-sqlite-*.sql.gz.enc 2>/dev/null || true)
[ "${#sets[@]}" -gt 0 ] || fail "no encrypted sets found at $SSH_HOST:$SOURCE_DIR"
# Verify what we hold against the digests written at backup time; a bad copy is removed and the run fails loudly.
bad=0
for f in "${sets[@]}"; do
  if ! ( cd "$OUT" && sha256sum -c --quiet "$(basename "$f").sha256" ) 2>/dev/null; then
    echo "digest mismatch: $f (removed; next run re-pulls it)" >&2; rm -f "$f"; bad=$((bad+1))
  fi
done
[ "$bad" -eq 0 ] || fail "$bad mirrored archive(s) failed their digest check"

for f in "${sets[@]:$KEEP}"; do
  stamp="${f##*/rupert-sqlite-}"; stamp="${stamp%%.sql.gz.enc}"
  rm -f "$f" "$f.sha256" "$f.plain.sha256" "$OUT/settings-$stamp.sql.enc" "$OUT/settings-$stamp.sql.enc".*sha256 "$OUT/env-sqlite-$stamp.enc" "$OUT/env-sqlite-$stamp.enc".*sha256
done

cloud=""
if [ -n "$RCLONE_REMOTE" ]; then
  command -v rclone >/dev/null || fail "RCLONE_REMOTE set but rclone is not installed"
  rclone sync --quiet "$OUT" "$RCLONE_REMOTE" || fail "rclone sync to $RCLONE_REMOTE failed"
  cloud="; cloud copy at $RCLONE_REMOTE"
fi

kept=$(ls -1 "$OUT"/rupert-sqlite-*.sql.gz.enc | wc -l)
newest="${sets[0]}"
write_status ok "mirror on $(hostname) verified; $kept sets kept$cloud" "$newest" "$(stat -c %s "$newest")" "$kept"
echo "mirror ok: $kept sets in $OUT (newest $(basename "$newest"))$cloud"
