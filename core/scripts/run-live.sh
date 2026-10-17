#!/usr/bin/env bash
# Local-only server for a real, read-only sync. Binds 127.0.0.1:8798, no dev flag, upstream ledger on.
# Config lives in ~/.config/rupert-core (override with RUPERT_LIVE_DIR). Nothing here is committed.
set -euo pipefail
DIR="${RUPERT_LIVE_DIR:-$HOME/.config/rupert-core}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$DIR" && chmod 700 "$DIR"
if [ ! -f "$DIR/master.key" ]; then
  python3 -I -c 'import base64,secrets;print(base64.b64encode(secrets.token_bytes(32)).decode())' > "$DIR/master.key"
  chmod 600 "$DIR/master.key"
fi
mkdir -p "$HERE/data-live"
exec env RUPERT_DATA="$HERE/data-live" RUPERT_MASTER_KEY="$(cat "$DIR/master.key")" \
  RUPERT_LISTEN="${RUPERT_LISTEN:-127.0.0.1:8798}" RUPERT_COOKIE_SECURE=0 RUPERT_BASE_DOMAIN=rupert.local \
  RUPERT_LOG_UPSTREAM=1 "${RUPERT_BIN:-$HERE/target/release/rupert-core}" 2> >(tee -a "$HERE/data-live/upstream.log" >&2)
