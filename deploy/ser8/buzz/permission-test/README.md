# Permission check for the @rupert agent

`run.sh` proves that the `buzz` agent in `../opencode.json` may only post with the `buzz` CLI and run Rupert's three
report scripts, using a mock model so no API key or relay is needed. It tries injection forms (`;`, `&&`, pipes,
newlines, `$()`, backticks, `$VAR`, `>`, `<`) and prints `ok` or `FAIL` per case. Rerun it after changing `opencode.json`
or the pinned opencode version (docs/ops/buzz-relay-ser8.md). `chmod +x run.sh` if needed; run it as an unprivileged user.
