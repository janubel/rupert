#!/usr/bin/env bash
# Adds Buzz public keys (64-hex) to the closed relay and to every channel, as the community owner. Run on the SER8 host.
# Feed it the hex keys printed by `bin/rails buzz:person_keys` in the rupert container (column 4), or pass them as args:
#   deploy/ser8/buzz/add-member.sh <hex> [<hex> ...]
#   incus exec rupert -- ... rails buzz:person_keys | cut -f4 | deploy/ser8/buzz/add-member.sh
# The owner key never leaves the `buzz` container. Re-running for a key that is already a member is harmless.
set -euo pipefail
RELAY="${RELAY:-https://buzz-herbalhealers.rupertpos.com}"
ROLE="${ROLE:-member}"
keys=("$@")
[ ${#keys[@]} -gt 0 ] || mapfile -t keys
for key in "${keys[@]}"; do
  key="$(echo "$key" | tr -d '[:space:]')"
  [[ "$key" =~ ^[0-9a-f]{64}$ ]] || { echo "skip: not a 64-hex public key: ${key:0:20}" >&2; continue; }
  incus exec buzz -- bash -c "cd /opt/buzz && ./run.sh add-member $key --role $ROLE" | tail -1
  sleep 1 # upstream: avoid same-second roster collisions
  incus exec buzz -- bash -c "export BUZZ_RELAY_URL=$RELAY BUZZ_PRIVATE_KEY=\$(cat /root/buzz-secrets/owner.key)
    buzz channels list | python3 -c 'import sys,json; [print(c[\"id\"]) for c in json.load(sys.stdin)]' | while read -r channel; do
      buzz channels add-member --channel \"\$channel\" --pubkey $key --role member >/dev/null && echo \"  added to channel \$channel\"
    done"
done
