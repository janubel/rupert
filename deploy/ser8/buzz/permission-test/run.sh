#!/usr/bin/env bash
# Check deploy/ser8/buzz/opencode.json against opencode with a mock model: every command in mock_llm.py CASES is
# tried by the `buzz` agent and must be allowed or denied as expected. Needs python3 and the pinned opencode.
#   ./run.sh [path/to/opencode] [path/to/opencode.json]
# Run it as an unprivileged user. It uses a throwaway HOME and never touches Rupert or a relay (the "allowed" buzz
# command fails with a connection or auth error; only the permission decision is checked).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
opencode="${1:-opencode}"
config="${2:-$here/../opencode.json}"
port="${MOCK_PORT:-8099}"
tmp="$(mktemp -d)"
trap 'kill "$mock" 2>/dev/null; rm -rf "$tmp"' EXIT

python3 - "$config" "$tmp/opencode.json" "$port" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c['model'] = 'mock/mock-1'
c['provider'] = {'mock': {'npm': '@ai-sdk/openai-compatible', 'name': 'Mock', 'options': {'baseURL': 'http://127.0.0.1:%s/v1' % sys.argv[3], 'apiKey': 'x'}, 'models': {'mock-1': {'name': 'mock-1', 'tool_call': True}}}}
json.dump(c, open(sys.argv[2], 'w'))
PY
python3 "$here/mock_llm.py" "$port" & mock=$!
sleep 1

declare -A expect=([ALLOWED]=allowed [QUICK]=allowed [HEREDOC]=allowed
  [FORBIDDEN]=denied [CHAINED]=denied [AMP]=denied [PIPE]=denied [NEWLINE]=denied [SUBST]=denied [BACKTICK]=denied
  [ENVVAR]=denied [REDIR]=denied [STDIN]=denied [HEREREAD]=denied)
fail=0
for tag in "${!expect[@]}"; do
  out="$(cd "$tmp" && HOME="$tmp" XDG_DATA_HOME="$tmp/d" XDG_CACHE_HOME="$tmp/c" XDG_STATE_HOME="$tmp/s" XDG_CONFIG_HOME="$tmp/cfg" \
    OPENCODE_CONFIG="$tmp/opencode.json" timeout 60 "$opencode" run --standalone --format json --agent buzz "$tag" 2>&1 < /dev/null)"
  got="$(printf '%s\n' "$out" | python3 "$here/outcome.py")"
  if [ "$got" = "${expect[$tag]}" ]; then echo "ok    $tag -> $got"; else echo "FAIL  $tag: expected ${expect[$tag]}, got $got"; fail=1; fi
done
[ ! -e /tmp/permission-test-pwned.txt ] || { echo "FAIL  redirect created /tmp/permission-test-pwned.txt"; rm -f /tmp/permission-test-pwned.txt; fail=1; }
exit $fail
