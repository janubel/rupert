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
- **Propose changes:** `create_task`, `update_task` and `submit_feedback` save an
  action card on the reply; nothing changes until someone allowed to make it presses
  **Approve**. It then runs as that person, and Rupert posts a notice saying what
  happened. People ask in plain words ("assign the tea shelf count to Jan, due
  Friday", "move it to done"): the bot finds the task with `list_tasks`, and
  `Mcp::Assignee` turns a name, email, "me" or "nobody" into one active person
  before the card is shown (a name shared by two people goes back to the bot to ask
  which one; the card pins that person by email). When the change gives the task
  to someone who uses team chat, the notice mentions them.
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

## Local model @agents (@lfm, @bonsai, @gemma)

Next to @rupert, people can @mention three open models that run on SER8 itself, to compare them on real questions.
Each answers with the same tools, permissions and approve-cards as @rupert (`TeamChat::LocalAgents`), and its reply
shows under its own name. They exist only when `RUPERT_LOCAL_LLM_URL` is set in `/etc/rupert.env`.

| Handle | Model | File (in `rupert-llm`) | Licence |
| --- | --- | --- | --- |
| `@lfm` | Liquid AI LFM2.5-8B-A1B (MoE, ~1B active) | `LFM2.5-8B-A1B-Q4_K_M.gguf`, 5.2 GB | LFM Open License (free under $10M revenue) |
| `@bonsai` | PrismML Ternary Bonsai 2 9B (ternary weights) | `Ternary-Bonsai-2-9B-PQ2_0.gguf`, 2.4 GB | Apache-2.0 |
| `@gemma` | Google Gemma 4 E4B (QAT q4_0) | `gemma-4-E4B_q4_0-it.gguf`, 5.2 GB | Apache-2.0 |

There is no LiquidAI "ternary" model; the ternary model is PrismML's Ternary Bonsai, which needs PrismML's llama.cpp
fork (upstream llama.cpp and Ollama cannot load its PQ2_0 packing). So all three run on that fork's prebuilt CPU build
(`prism-b10787`), not Ollama.

**One model at a time.** `deploy/ser8/team-chat/llm-gateway/llm_gateway.py` runs in the `rupert-llm` Incus container
(10.96.131.7, 8 CPUs, 14 GiB) as `rupert-llm-gateway.service`. It is an OpenAI-compatible endpoint
(`http://10.96.131.7:8080/v1`) in front of a single `llama-server`:

- a request for a model that is not loaded waits for the request in flight, stops the running model and starts the
  requested one; requests are served one at a time, so two models are never in memory together;
- a model with no request for 10 minutes (`--idle-seconds 600`) is unloaded; the next mention loads it again (Bonsai
  loaded in 9 s);
- only `rupert` (10.96.131.8) and localhost may call it (the gateway checks, and the Incus ACL `rupert-llm-isolated`
  drops all other inbound traffic and ALL outbound traffic: the container needs no internet once the models are in);
  `GET /health` says which model is loaded.
- Measured on SER8's CPU (8 threads, 2026-10-22): LFM2.5 17–21 tokens/s, Gemma 4 ~11, Ternary Bonsai ~11–13; a model
  loads in about 9 s. All three made native tool calls. Thinking is off for Bonsai and Gemma (`--chat-template-kwargs`)
  so they answer straight away; LFM2.5 thinks first (its template always opens `<think>`). In a quick check LFM2.5 used
  the wrong year for "yesterday" and Gemma/Bonsai sometimes answer from memory instead of calling `where_is`: these are
  for trying out, @rupert stays the dependable assistant.
- The container needs the same `raw.apparmor` signal rule as `rupert` (copied from it); without it systemd and the
  gateway cannot stop processes ("Permission denied") and models could not be swapped or unloaded.

In the room the reply shows "Loading Gemma 4" / "Waiting for Gemma 4" until the model answers. Rupert allows a local
reply up to 10 minutes per model call (it may be queued behind another model).

**Enable:** add `RUPERT_LOCAL_LLM_URL=http://10.96.131.7:8080/v1` to `/etc/rupert.env`; it takes effect the next time
rupert-web and rupert-jobs restart (every deploy restarts them).

**Install or rebuild `rupert-llm`:** see `deploy/ser8/team-chat/llm-gateway/README.md`.

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

## Bots and #admins (2026-10-22)

- The main room is **#admins**: every admin, plus Rupert. An existing #general is renamed in place, and old `/chat/general` links still open it.
- **Direct** lists every other admin. A click opens the direct message, or starts it the first time.
- Bots are @mentioned. @ suggestions work in the main box and in thread replies, and the 🤖 Bots key in the room header explains each one:

| Mention | Model | Where it runs |
| --- | --- | --- |
| `@rupert` | DeepSeek V4.1 Flash (`RUPERT_CHAT_PROVIDER=opencode_go`, `RUPERT_CHAT_MODEL=deepseek-v4.1-flash`) | cloud, OpenCode Go plan |
| `@liquid` | Liquid AI LFM2.5 8B-A1B | local `rupert-llm` gateway |
| `@qwen` | Qwen3.5 4B | local |
| `@gemma` | Google Gemma 4 E4B (`gemma-4-e4b`, `gemma-4-E4B_q4_0-it.gguf`) | local (added back 2026-10-23 at the owner's request) |

- Every bot reply shows its time and model, for example "4s · deepseek-v4.1-flash · cloud".
- Replies from the old handles still show proper names: @lfm shows as Liquid, and @ternary/@bonsai replies still show as Ternary. **@ternary was removed on 2026-10-23 (too slow); its model file was deleted from `rupert-llm`.** @deepseek is retired as a handle (it is @rupert now).

## Replies, Media and people (2026-10-22)

- **↩ Reply** quotes a message (in the room or in a thread). The quoted id lives in
  `meta['quote_id']` on the person's message; the payload carries a short `quote`
  preview. Replying to a bot's answer without naming a bot asks that bot again, and
  the bot sees "(replying to …)" in its context. **💬 Thread** opens the side thread.
- **Media** tab (`GET /chat/:room/media.json?q=&kind=images|files&before=`): the
  room's photos and files, newest first, searchable by file name, message text and
  poster name or email; "Show in chat" jumps to the message (or its thread).
- Hovering a person shows their email (two accounts can share a name); @
  suggestions and the direct-message list show it too.

## Recently active (2026-10-23)

- `users.last_active_at` is set at most once a minute by any signed-in HTML page
  view (`AuthenticatedController#note_presence`) and by chat polls while the tab is
  in front. A green dot means active in the last 5 minutes; a ring, within the
  hour; hover shows "Active 23 min ago". Shown on the rail, room members, direct
  message header, message avatars and the dock.
- Each person can hide theirs ("Shown as active · change" under their name in the
  rail): `users.presence_hidden`.
- Administrators set a workspace rule in the same dialog: Everyone = "Each person
  chooses" (default), "Always shown" or "Never shown", with an override per role
  (Rupert's groups). The rule is the `team_chat_presence` Setting
  (`TeamChat::Presence`); "Always"/"Never" override what people chose.

## Test battery and the 2-minute goal (2026-10-23)

- New read-only tools for every bot: `period_review` (day, week, pay week, month,
  quarter, year vs the period before), `compliance_check` (Books check, month and
  quarter close, people queues, Uploads, Drive retention, sales tax filings marked
  unknown) and `order_queues` (unshipped, unpaid, stock requests, purchase orders,
  receipts, holds, unresolved card payments, follow-ups).
- `bin/rails team_chat:battery AGENT=liquid USER_EMAIL=…` asks the 21 questions in
  `config/team_chat/battery.yml` one at a time in **#liquid-testing**, isolated from
  each other, times each answer, and has DeepSeek (OpenCode Go) grade it 1–5 against
  what Rupert's own tools return. Proposals are dismissed; a summary is pinned and a
  markdown report saved under `tmp/battery/`. `AGENT` can be any @bot, `rupert`, or a
  trial model (`gemma-e2b`, `gemma-e4b-ud`) that is on the gateway but not @mentionable.
  It must run in the production container: only it can reach the `rupert-llm` gateway.
- Goal: every answer within 2 minutes. Slower answers log `[TeamChat] slow answer …`
  and a `team_chat_slow_answer` activity, and are listed on **Model scores** with each
  model's share over 2 minutes.
- Gateway models (`/etc/rupert-llm/models.json`, mirrored in
  `deploy/ser8/team-chat/llm-gateway/models.json`): adding one needs
  `systemctl restart rupert-llm-gateway` inside `rupert-llm` (the list is read at start).

## Local models on the Radeon 780M (2026-10-22)

SER8 is an AMD Ryzen 7 8745HS with a Radeon 780M integrated GPU. Since 2026-10-22 the `rupert-llm` gateway runs the
official llama.cpp **Vulkan** build (`b11819`, `/opt/llama/llama-b11819-vulkan`, `/opt/llama/current` points to it)
with `--n-gpu-layers 99` for every model. The GPU is passed in as `gpu0` (`incus config device add rupert-llm gpu0 gpu
gid=990 mode=0660`, gid 990 = the container's `llm` group); `mesa-vulkan-drivers` and `libvulkan1` were downloaded on
the host and installed with `dpkg -i` (the container still has no internet). The PrismML CPU build stays in
`/opt/llama/llama-prism-b10787-73bfe6c`; Ternary Bonsai, the only model that needed it, is gone.

`llama-bench` on SER8 (same files, 8 threads, tokens per second):

| Model | Prompt 4096, CPU | Prompt 4096, 780M | Generate, CPU | Generate, 780M |
| --- | --- | --- | --- | --- |
| LFM2.5 8B-A1B Q4_K_M (@liquid) | 253 | 1,219 | 46 | 66 |
| Gemma 4 E4B QAT Q4_0 (@gemma) | 118 | 698 | 14 | 25 |
| Gemma 4 E4B UD-Q4_K_XL | 136 | 555 | 15 | 23 |
| Gemma 4 E2B UD-Q4_K_XL | 264 | 1,035 | 26 | 44 |

A bot answer reads ~8,000 prompt tokens (instructions + tool list) twice and writes ~100–300, so reading dominates.
Through Rupert, "How were sales yesterday?" went from 112 s to 22 s for @gemma and takes 18 s for @liquid; models load
in 2–4 s.

**Rollback to CPU** (inside `rupert-llm`): `ln -sfn /opt/llama/llama-prism-b10787-73bfe6c /opt/llama/current`,
`cp /etc/rupert-llm/models.json.cpu-20261022 /etc/rupert-llm/models.json`, `systemctl restart rupert-llm-gateway`.

The test battery shares the gateway with people: while it runs, a person's @bot question waits behind the battery's
current question (one model at a time). Run it when nobody is chatting, or expect short waits.

### Tuning on the 780M (2026-10-22)

`llama-bench` sweep inside `rupert-llm` (prompt 4096 tokens, tokens/s; generation speed did not change with any setting):

| Model | default | flash attention + best ubatch | ubatch |
| --- | --- | --- | --- |
| LFM2.5 8B-A1B | 921 | 1,212 | 2048 |
| LFM2.5 24B-A2B (QAD Q4_0) | 584 | 893 | 2048 |
| Gemma 4 E4B | 639 | 691 | 1024 |
| Qwen3.5 4B | 465 | 481 | 512 |

q8_0 KV cache gave no speed (memory only), so it is not used. Every model now runs with `--flash-attn on --batch-size 2048`
and its best `--ubatch-size` (models.json). GPU memory is not charged to the container's 14 GiB limit (a 13 GB model left
the container at ~230 MB); the real limits are the 780M's 17.3 GB (4 GB BIOS carve-out + 13.3 GB GTT) and host RAM.
Backups: `/etc/rupert-llm/models.json.pre-tune-20261022`.

The gateway logs one line per request: `prompt_new` (tokens read), `prompt_cached` (reused from the previous request),
`prompt_tps`, `gen`, `gen_tps` (`journalctl -u rupert-llm-gateway`). Within one answer the second step reuses the first
(~9,000 cached tokens, under a second); a new question currently re-reads the whole prompt (~8 s for 9,000 tokens),
because per-question parts come early in the prompt.

Test models on the gateway (battery only, `AGENT=lfm-24b` / `qwen-35b`): LFM2.5-24B-A2B QAD-Q4_0 (13.6 GB) and
Qwen3.6-35B-A3B Unsloth UD-Q3_K_S (15.4 GB).
