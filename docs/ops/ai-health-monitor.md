# AI health monitor (opencode)

Shows on **System → AI health · opencode** and over MCP as `ai_health`
(see [mcp.md](../mcp.md)). It watches the opencode integration behind the
@rupert Buzz agent (`web/app/services/opencode_chat_agent.rb`, run by
`web/bin/opencode_agent`). It spends **no tokens**, stores **no key and no
message content**, and is instance-wide (one key and one agent per server), so
its tables have no tenant column and only a platform administrator sees it.

## What it checks

`AiHealthCheckJob` runs every 30 minutes (`config/recurring.yml`) and on demand
(**Check now**, throttled to once per 20 s). Each check, in `OpencodeHealth`:

1. `GET https://opencode.ai/zen/v1/models` (public) — the **live** free-model
   list: every id ending in `-free`. Never hard-coded; sources disagree and it
   changes.
2. `GET <provider>/models` **with the key** — opencode answers `401` for a bad
   key, with a machine code such as `api_key_expired`, so key validity costs
   nothing. A `200` also gives that provider's catalog, which tells whether the
   configured model is still offered. Provider is OpenCode Go
   (`https://opencode.ai/zen/go/v1`, default) or Zen.
3. Optional (`OPENCODE_HEALTH_PROBE=1`): one 1-token chat call to the first free
   model, to see IP-level rate limits before the agent trips them. Off by
   default.

Recorded per check: key state (valid / expired / rejected / not set), latency,
HTTP status, error type (`auth`, `rate_limited`, `timeout`, `network`,
`server_error`, `unexpected_response`), the vendor's error *code* (never message
text), free models, whether the model is available, and whether a `429` was seen
(with `Retry-After`). Checks older than 90 days are pruned.

## Token counts

opencode documents **no balance or usage API** for Zen or Go — usage is only in
the web console (<https://opencode.ai/docs/zen/>, <https://opencode.ai/docs/go/>;
checked 2026-10-21). The card says so instead of inventing a balance.

Tokens come from the agent itself: `opencode run --format json` prints a
`step_finish` event per model step with `tokens.input/output/reasoning/cache`
and `cost`. `OpencodeChatAgent#generate_reply` passes that output to
`OpencodeUsage`, which stores one `ai_agent_runs` row per run: token counts,
outcome (`ok`, `empty`, `error`, `rate_limited`, `timeout`), error type and
duration. Failures to record only log a warning and never affect the reply.
Rows are pruned after 180 days. Reading opencode's local `opencode.db` is not
needed and is not implemented.

## Configuration (environment, instance-wide)

| Variable | Default | Meaning |
| --- | --- | --- |
| `OPENCODE_API_KEY` | from auth file | The key the monitor validates. Sent only to opencode.ai. |
| `OPENCODE_AUTH_FILE` | `~/.local/share/opencode/auth.json` | opencode's own credential file; the `opencode-go` (or `opencode`) entry is used when `OPENCODE_API_KEY` is unset. |
| `OPENCODE_PROVIDER` | `go` | `go` or `zen`: which catalog the key is checked against. |
| `OPENCODE_MODEL` | `deepseek-v4-flash` | The model the agent uses. Must match the `chat` agent's model in opencode's config; a `opencode-go/` or `opencode/` prefix is ignored. |
| `OPENCODE_HEALTH_PROBE` | off | `1` enables the 1-token free-model probe. |

The Rails app must be able to read the key: set `OPENCODE_API_KEY` for the Rupert
service (or mount the auth file) wherever the jobs and the agent run.

## Findings when this was built (2026-10-21) — act on these

- The `opencode-go` key in `~/.local/share/opencode/auth.json` on SER8 is
  **expired** (`401 api_key_expired` on both `/models` and chat). Create a new
  key in the OpenCode Console and replace it. The card shows this as
  "Expired" once the monitor can read a key.
- opencode on SER8 is v2.0.32, and `opencode run` there **rejects `--pure` and
  `--dir`** (`Unrecognized flag`). `OpencodeChatAgent` still passes both, so the
  agent would produce no reply; the monitor now records such runs as
  `error / no_output` and warns "N of the agent's last runs failed". No agent
  process or `chat` agent config was found on SER8 either — this was left
  unchanged (out of scope for the monitor) and needs its own fix.
- `deepseek-v4-flash` is in the Zen catalog but **not** in the Go catalog
  (Go has `deepseek-v4.1-flash` and `deepseek-v4-pro`). With the default
  `OPENCODE_PROVIDER=go` the card will report the model as "Not offered" if the
  agent is really on Go; set `OPENCODE_PROVIDER=zen` or `OPENCODE_MODEL` to match
  what the agent actually uses.
- Free ids on Zen today: `beam-free`, `deepseek-v4.1-flash-free`,
  `flint-40b-free`, `glm-5.3-flash-free`, `jev-1.13-free`,
  `longcat-2.5-preview-free`, `mimo-v2.6-flash-free`,
  `minimax-m3.1-flash-free`, `nemotron-3.5-lightning-free`,
  `nemotron-3.5-super-vl-free`. `big-pickle` is documented as free but has no
  `-free` suffix, so the monitor does not count it — the docs list and the
  suffix rule disagree, which is why the list is read live. Go lists only
  `beam-free`, `longcat-2.5-preview-free`, `minimax-m3.1-flash-free`.
- The exact JSON shape of an opencode rate-limit error was not observed (it
  can't be provoked on demand). Runs are classified `rate_limited` by status 429
  or wording such as "rate limit", "too many requests", "free usage limit"; once
  a real one is logged, check `ai_agent_runs.error_type` and tighten
  `OpencodeUsage::RATE_LIMIT` if it was missed.

## Follow-up (not done): local Ollama benchmark note

On SER8 (Ryzen 7 8745HS, 26 GB, iGPU only) `ollama list` shows `gemma4:e4b` and
`gemma4:latest` with the **same image ID** (`c6eb396dbd59`, 9.6 GB): they are the
same weights under two tags, so comparing them tells nothing. A useful
comparison is gemma4 against `qwen3.8:latest` (17 GB, likely too slow on an iGPU).
No benchmark was run, to keep load off production; if wanted, run it in a quiet
window with a fixed 5-prompt set and record tokens/s from
`ollama run --verbose`.
