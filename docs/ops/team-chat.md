# Team chat (/chat)

Slack-style rooms inside Rupert, with **@rupert** as a member who answers from
Rupert's own data. It replaces the Buzz relay + mirror (archived on the
`archive/buzz` branch): no relay, no second database, no sync. Messages are rows
in Rupert's own database.

**Who:** administrators only (`settings.write`), under System → Team chat.

## How it works

| Piece | Where |
| --- | --- |
| Rooms, members, messages | `TeamChat::Room`, `Membership`, `Message` (`chat_*` tables) |
| Images and files | `TeamChat::Attachment`: PNG, JPEG, GIF, WebP, PDF, CSV, TXT; ≤ 8 MB, ≤ 4 per message; type judged by bytes; stored in the database; served only to people who can open the room (`nosniff`, sandboxed). Large photos are scaled down in the browser first |
| @mentions | `@rupert` and anyone who can use team chat (autocomplete). Mentioned people join the room; mentions show as a red `@N` badge and a highlighted message |
| Reactions | `TeamChat::Reaction`: 👍 ❤️ 😂 🎉 👀 ✅ 🙏 🔥, toggled per person |
| Page + JSON polling | `TeamChatController`, `team_chat_controller.js` (1 s while Rupert is writing, 3 s otherwise) |
| Posting and triggers | `TeamChat::Post`: answers on `@rupert`, on every message (room setting), or never |
| The assistant | `TeamChat::Agent` (RubyLLM, native tool calling), run by `TeamChat::ReplyJob` |
| Persona | `config/team_chat/soul.md` (identity, voice, values, boundaries) |
| Tools | `TeamChat::Toolbox`: Ask Rupert's lookups + every read-only MCP tool the asker may use |
| Changes | `TeamChat::Actions`: write tools only *propose*; a person presses Approve |

Polling, not WebSockets: production runs SQLite without Redis, and polling local
rows survives deploys.

### What @rupert can do

- **Look things up:** `where_is`, `how_do_i`, `search`, `system_status` and the
  read-only MCP tools (sales, sales tax, stock, SwipeSimple items, time keeping,
  tasks, alerts, uploads, history, system health). They run in-process **as the
  person who asked**, with that person's permissions. Contact details are removed
  before the model sees results.
- **Propose changes:** `create_task` and `submit_feedback` save an action card on
  the reply. Nothing happens until someone allowed to make that change presses
  **Approve**. It then runs as that person, and Rupert posts a notice saying what
  happened. Dismiss runs nothing.
- **Context:** the last 30 room messages, or the whole thread when asked in a
  thread. Messages are passed as "Name: text" and treated as untrusted data.

Everyone in a room reads @rupert's reply. While the feature is admin-only that
is fine. Before opening rooms to staff, the toolset must be limited to what
every member of the room may see.

### Automatic notices (#announcements)

Rupert's own posts go into the **#announcements** room as notices
(`TeamChat::Notices`, posted later by `TeamChat::NoticeJob`):

- sync results and sync failures (`SyncJob`);
- inventory count submissions;
- sales announcements (`SalesAnnouncer`);
- the operations brief (`OperationsBrief`);
- fulfillment alerts (`FulfillmentMonitor`).

The room is created on the first notice. Nothing is posted until team chat has
been opened once in the workspace, so a fresh install stays quiet. A failed
post is logged and never stops the sync or job that sent it. Mention `@rupert`
in the room to ask about a notice.

## Model

RubyLLM (`ruby_llm` 2.1), used without its own chat tables. Pick the model with
instance environment variables in `/etc/rupert.env`, never a web setting:

| Variable | Meaning |
| --- | --- |
| `RUPERT_CHAT_PROVIDER` | `opencode_go`, `ollama`, `openai` (any OpenAI-compatible server) or `opencode_cli`. Unset = auto |
| `RUPERT_CHAT_MODEL` | Model id. OpenCode Go default `deepseek-v4.1-flash` |
| `RUPERT_CHAT_API_BASE` | Base URL for `openai`, or an override for the others |
| `RUPERT_CHAT_API_KEY` | Key for `opencode_go` / `openai` |

**Auto** picks, in this order:

1. **OpenCode Go** (`https://opencode.ai/inference/go/openai/v1`) when a key is
   set, or when Ask Rupert's `opencode auth login` saved one in
   `$OPENCODE_STATE_DIR/data/opencode/auth.json`.
2. **Ollama** when `OLLAMA_URL` and `ASK_RUPERT_LOCAL_MODEL` (or
   `RUPERT_CHAT_MODEL`) are set; its `/v1` API is used.
3. **The opencode CLI** Ask Rupert already uses, with a text tool protocol.

In auto, a refused or unreachable HTTP model falls back to the CLI. The model in
use is shown under the composer and in the rail.

### Local model on SER8

Run Ollama in its own Incus container, never inside `rupert`:

```bash
bash deploy/ser8/team-chat/setup-local-model.sh            # qwen3.5:4b + gemma4:e2b
```

Then in `rupert`'s `/etc/rupert.env`:

```
OLLAMA_URL=http://rupert-llm.incus:11434
RUPERT_CHAT_PROVIDER=ollama
RUPERT_CHAT_MODEL=qwen3.5:4b
```

Compare models on real questions without posting anything (every run is rolled back):

```bash
RUPERT_CHAT_MODEL=gemma4:e2b bin/rails team_chat:try
RUPERT_CHAT_MODEL=qwen3.5:4b bin/rails team_chat:try QUESTIONS="How were sales yesterday?|Any alerts?"
```

| Model | Ollama tag | Size | Tool calling (vendor) | Notes |
| --- | --- | --- | --- | --- |
| Qwen3.5 4B | `qwen3.5:4b` | 3.3 GB | TAU2 79.9, BFCL-V4 50.3 | Recommended small model; won our bake-off (PR #301) |
| Gemma 4 E2B | `gemma4:e2b` | 4.6 GB | Tau2 24.5 | Fast, weak at tools |
| Qwen3.5 35B-A3B | `qwen3.5:35b-a3b` | 22 GB | TAU2 81.2, BFCL-V4 67.3 | MoE (3B active); only with enough free RAM |

Prefer the official Ollama library tags over `hf.co/...` GGUF pulls; tool
calling is only reliable with the library's chat templates.

## Buzz (removed)

Buzz has been removed from `main`. Its code (relay setup, mirror, `@rupert`
agent container, `BUZZ_*` settings, the Buzz card and badge, the feedback
intake scripts) is preserved on the `archive/buzz` branch.

- Rupert's notices that went to Buzz channels now go to **#announcements**
  (above).
- The `BUZZ_*` keys, the `buzz.read` / `buzz.post` permissions, Ask Rupert's
  Buzz switch and the Settings → Buzz agent card are gone.
- The Buzz tables (`buzz_messages`, `buzz_identities`, `buzz_person_keys`,
  `buzz_profiles`, `buzz_chat_states`) are kept for now, with their data. A
  later change drops them.
- Older reports filed from Buzz keep `source` `buzz`. MCP `submit_feedback`
  still accepts `source: "buzz"` so older callers keep working.

**Operator step on SER8**, after this change has deployed: stop the `buzz` and
`rupert-agent` Incus containers (`incus stop buzz rupert-agent`), and disable
the host's `buzz-backup.timer` if it was installed
(`systemctl --user disable --now buzz-backup.timer`). Do not delete the
containers yet.
