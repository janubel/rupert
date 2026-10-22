#!/usr/bin/env bash
# Proves, with a mock model (no API key, no relay), that the `rupert` agent in ../opencode.json is offered ONLY the bridge's
# tools and cannot reach shell, file or web tools. Needs python3 and the pinned opencode (1.19.3). Run as an unprivileged
# user; it uses a throwaway HOME. Rerun after changing opencode.json, the bridge or the opencode version.
#   ./run.sh [path/to/opencode] [path/to/opencode.json] [path/to/rupert_mcp_bridge.py]
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
opencode="${1:-opencode}"
config="${2:-$here/../opencode.json}"
bridge="${3:-$here/../rupert_mcp_bridge.py}"
port="${MOCK_PORT:-8099}"
tmp="$(mktemp -d)"
trap 'kill "$mock" 2>/dev/null; rm -rf "$tmp"' EXIT

python3 - "$config" "$tmp/opencode.json" "$port" "$bridge" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c['model'] = 'mock/mock-1'
c['provider'] = {'mock': {'npm': '@ai-sdk/openai-compatible', 'name': 'Mock', 'options': {'baseURL': 'http://127.0.0.1:%s/v1' % sys.argv[3], 'apiKey': 'x'}, 'models': {'mock-1': {'name': 'mock-1', 'tool_call': True}}}}
c['mcp']['rupert']['command'] = ['python3', sys.argv[4]]
json.dump(c, open(sys.argv[2], 'w'))
PY
python3 "$here/mock_llm.py" "$port" 2> "$tmp/mock.err" & mock=$!
sleep 1

run() { (cd "$tmp" && HOME="$tmp" XDG_DATA_HOME="$tmp/d" XDG_CACHE_HOME="$tmp/c" XDG_STATE_HOME="$tmp/s" XDG_CONFIG_HOME="$tmp/cfg" \
  OPENCODE_CONFIG="$tmp/opencode.json" timeout 60 "$opencode" run --pure --format json --agent rupert "$1" 2>&1 < /dev/null); }

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: expected '$3', got '$2'"; fail=1; fi; }

run "TOOL:buzz_reply hello" > "$tmp/out1.txt"
offered="$(grep 'offered tools=' "$tmp/mock.err" | tail -1 | sed "s/.*offered tools=//; s/ picked=.*//")"
check "the model is offered exactly the bridge's reply tool" "$offered" "['rupert_buzz_reply']"
check "calling it reaches the bridge (buzz fails here: no relay or key)" "$(grep -c 'buzz failed\|posted' "$tmp/out1.txt" | sed 's/^[1-9].*/yes/')" "yes"

: > "$tmp/mock.err"
run "FORBIDDEN please" > "$tmp/out2.txt"
check "a shell command cannot be called" "$(grep -c "unavailable tool\|not an available tool\|Available tools: rupert_buzz_reply" "$tmp/out2.txt" | sed 's/^[1-9].*/yes/')" "yes"
[ ! -e /root/permission-test-should-not-exist ] || fail=1
exit $fail
