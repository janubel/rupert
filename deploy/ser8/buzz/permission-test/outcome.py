import json, sys
# Reads `opencode run --format json` events on stdin; prints "allowed" if the shell tool ran, "denied" if the
# permission engine refused it, otherwise "none".
result = 'none'
for line in sys.stdin:
    try:
        event = json.loads(line)
    except ValueError:
        continue
    part = event.get('part') or {}
    if event.get('type') == 'tool_use' and part.get('tool') == 'shell':
        state = part.get('state') or {}
        result = 'denied' if 'Permission denied' in str(state.get('error')) else 'allowed'
print(result)
