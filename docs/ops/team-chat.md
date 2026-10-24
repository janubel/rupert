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
- `--keep-loaded qwen3.6-35b-a3b` (since 2026-10-22): @qwen's model is never unloaded for being idle, and once another
  model has been idle for 10 minutes the gateway puts Qwen back, so @qwen does not wait ~17 s for a load. The 780M
  shares system RAM, so this holds about 15 GB of SER8's memory while it is loaded;
- `/health` reports the last load (model, seconds, when, and `reason`: `request` or `keep_loaded`). A local reply that
  waited for a load records `load_ms` and shows it with the answer time ("31s (17s load) · qwen3.6-35b-a3b · local");
  battery results carry `load_seconds`. Use these to judge how long models should stay loaded;
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
| `@qwen` | Qwen3.6 35B-A3B (Unsloth MTP UD-IQ3_S, draft-mtp) since 2026-10-22; was Qwen3.5 4B (now the `qwen-4b` test model) | local |
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

### @qwen is Qwen3.6-35B-A3B (2026-10-22)

The test battery put Qwen3.6-35B-A3B first among local models (finance 4.62, general 4.33, about 15 s; see
`docs/ops/local-ai-report-2026-10-22.md`), so it now answers as @qwen. It fills the 780M on its own (about 2 GB left), which
the one-model-at-a-time gateway already handles. Qwen3.5-4B stays on the gateway as the `qwen-4b` test model. The bot key's
grades and 💰 badge follow the model, so they carry over from the runs made under `qwen-35b`.

### @qwen uses multi-token prediction (2026-10-22)

`unsloth/Qwen3.6-35B-A3B-MTP-GGUF` (UD-IQ3_S, 15.3 GB) keeps Qwen's own multi-token-prediction head, and llama.cpp
b11819 uses it with `--spec-type draft-mtp --spec-draft-n-max 3`: the model drafts the next three tokens and checks them
in one pass. A/B on the finance battery (21 questions each, DeepSeek grading, same day):

| Setup | Grade | Time per answer | Writing speed |
| --- | --- | --- | --- |
| UD-Q3_K_S, no speculation (before) | 4.3 | 14.5 s | 22.7 tok/s |
| MTP file, no speculation | 4.3 | 13.4 s | 24.9 tok/s |
| MTP file, `draft-mtp` n-max 3 (now) | 4.3 | 12.5 s | 37.9 tok/s |

99% of drafted tokens were accepted in the probe. `--spec-draft-n-max 2` made llama-server exit, so it stays at 3.
n-gram speculation was tried earlier and dropped: it only helps when an answer repeats text word for word. Rollback:
`/etc/rupert-llm/models.json.pre-mtp`. The UD-Q3_K_S file stays on the gateway until it is deleted by hand.

### Dedicated inference worker

`TeamChat::ReplyJob` and `AskRupertReplyJob` use the `chat` queue. `config/queue.yml`
starts a dedicated one-thread, one-process chat worker beside the operational
`default` worker under the existing `bin/jobs` Solid Queue supervisor. On SER8,
`rupert-jobs.service` owns both worker processes, so normal deployment restarts
and service health checks still apply. `JOB_THREADS` and `JOB_CONCURRENCY` tune
only the operational pool; inference remains serialized in its own pool.
Do not restore a wildcard operational queue: it would also claim chat jobs.

Before first rollout, drain any previously queued `TeamChat::ReplyJob` and
`AskRupertReplyJob` entries on `default` (including scheduled retries), and let
claimed replies finish. Persisted jobs retain their original queue; changing
`queue_as` only routes new enqueues. Inspect ready, scheduled, and claimed job
counts before restarting. Do not delete pending replies or run two supervisors
against a legacy inference backlog as a substitute for draining it.

After restart, verify two registered Worker processes with distinct queue metadata
(`default` and `chat`), and one chat execution at most. A blocked inference must
leave the default worker claiming operational jobs. This isolates execution slots,
not the shared SQLite writer, CPU, memory, or network; tools must still keep database
transactions short. `test/jobs/chat_worker_isolation_test.rb` exercises a blocked
real Solid Queue execution with sync, monitor, and backup probes, without model or
vendor calls. Adding another named application queue requires updating the worker
configuration and routing regression.

### Checking answers (RUPERT_VERIFY, 2026-10-22)

`RUPERT_VERIFY=1` (every local bot) or `RUPERT_VERIFY=qwen-4b,qwen-2b` (named bots) adds two passes after a local
bot answers (`TeamChat::Verify`):

1. **Check.** The answer is split into sentences. Rupert checks every number in them against the tool data itself
   ($ and % with the number check, and every other figure the same way; dates, times and years are skipped). The same
   model then gets only those sentences and the tool data (never the conversation or its own reasoning) and returns a
   verdict per sentence (`supported` / `contradicted` / `not_found` / `no_fact`, JSON schema enforced by llama-server).
   A sentence fails when it has a figure the data does not have, or when the model shows the data contradicts it with a
   quote that Rupert confirms is really in the data. The model's `not_found` alone fails nothing: small models miss
   evidence that is there.
2. **Fix**, only when something failed. The model gets the failed sentences and why, and returns a replacement (or an
   empty one to remove the sentence) for each. Rupert puts them in place of those sentences, so the rest of the answer
   stays word for word, and skips any replacement with a figure the data does not have. One round, no loops.

Both passes use the same system prompt and start with the same DATA block, so the model server reuses it for the fix.

The first version (#372) let the model rewrite the whole answer and trusted its "not found": in the smoke test it
deleted a correct paragraph and flagged sentences whose only number was the year. This version fixes both.

Why this shape: prompted self-correction without outside evidence makes models worse (Huang et al. 2023; small models
especially, and challenged models flip right answers about half the time, FlipFlop 2023). Checking claims against tool
evidence works (CRITIC 2023), and verification that cannot see the draft repeats fewer of its mistakes (Chain-of-
Verification 2023). Sentence-level checks are enough (MiniCheck 2024). The reply's `meta['verify']` records claims,
failures, whether a fix was tried and kept, the time taken and the draft when it was replaced. The battery saves such
runs under their own set name (`finance+verify`), so the bot key's scores stay those of plain runs.
### Durable room replies

Every new room assistant reply creates a private `chat_runs` row in the same
transaction as its pending message. The row is the enqueue outbox: the default
queue's `TeamChat::RecoverRunsJob` scans every minute, dispatches queued or
abandoned runs to `chat`, and expires deadlines without depending on a browser.
Existing legacy replies acquire a run when their reply job executes.

A conditional SQL update claims one owner token for a 30-second lease, renewed
every five seconds. Every transcript checkpoint, tool start, proposal receipt,
and public reply write checks that token, lease, and deadline. Reclaimed workers
cannot publish or start another tool. Three claims are allowed; recovery fails
an exhausted run. Duplicate queue deliveries do not consume another claim while
the owner is live. Recovery enqueue attempts are throttled to once a minute.

The deadline is fixed at message creation: two minutes for @rupert and five for
local agents, including queue wait and all model/tool rounds. Native requests
use the remaining budget with HTTP retries disabled. Stop is available only to
the person who requested the reply, subject to existing room access. It cancels
the run, releases silent native HTTP execution, and dismisses unapproved cards;
already approved changes remain intact. Deadline expiration does the same with
a time-limit message. An already running read tool finishes its own bounded I/O;
its result and subsequent writes are rejected after cancellation or lease loss.
Stopping Rupert does not guarantee cancellation of provider-side billing.

Native RubyLLM transcripts checkpoint after each generation/tool batch. Tool
results have stable per-step IDs; proposal creation and its replay receipt share
a transaction, preventing duplicate approval cards across a crash between tool
execution and the next model request. CLI tool rounds also persist their
transcript and reuse receipts after restart. Step and tool budgets carry across
recovery. A changed engine/model/endpoint fails recovery rather than silently
continuing on another route. Private transcripts and receipts are never included
in room JSON. The floating Ask Rupert panel retains its existing execution model.

Deploy the additive `CreateChatRuns` migration before restarting workers and the
Solid Queue scheduler. Verify the recovery schedule is registered. Recovery can
take a lease interval plus the next minute scan and chat queue wait; it does not
extend a reply's deadline. Regression coverage includes simultaneous claims,
actual SIGKILL/restart replay, stale-owner fencing, cancellation during silent
HTTP, deadlines, CLI replay, and cancellation authorization.

### Durable tool approvals and attribution

New action cards have canonical `chat_approvals` records; message JSON is only
the existing UI projection. The immutable proposal contains the exact tool
arguments, a UUID, and requester provenance. The audit events record proposal,
approval/dismissal, execution/failure, and cancellation, with actors and times.
Terminal receipts cannot be edited through the model; audit event instances are
read-only after creation. A hard-deleted chat message nulls the live message
reference but retains the approval, receipt, source snapshot and audit events.
These records follow tenant scoping and existing room access checks.

Approve/dismiss runs under the message lock. For the explicit local allow-list
(`create_task`, `update_task`, `submit_feedback`), the database mutation, receipt,
audit events, activity entry, card projection and room notice commit in one
transaction. Expected tool failures roll back partial writes in a savepoint
before committing a failed receipt. A crash before commit rolls everything back;
a retry can execute once. A crash or lost HTTP response after commit returns the
saved receipt without another mutation or notice. The same decision is idempotent;
a conflicting decision is rejected. Permission and room access are checked again
on every request, including receipt replay. Unexpected errors leave the proposal
retryable instead of committing a false success. Failed receipts do not retry the
tool; ask for a new proposal after addressing the failure.

This protocol covers local database writes, not arbitrary remote effects. Do not
add Shopify, Square, email, or other external writes to the allow-list without a
provider idempotency/reconciliation design and their required user authorization.

The requester is the person whose message triggered the run, independently of
who approves. The run snapshots that message when it is created, including its
text, timestamp, author and thread. Later messages and edits cannot change it.
Approval provenance records the model, engine, harness/version, loaded build,
proposal time, requesting message and room URL; execution events add duration
and result references. CLI fallback proposals record their actual CLI route.
For task creation the description names the requester and links the source chat;
creation, updates and closing also write structured provenance to the task's
`team_chat_action` activity entry. The approver remains the action's actor.
Requester attribution never implies assignment. Explicit assignees remain pinned
to their identity; even “assign to me” refers to the requester, not the approver.
An unavailable or changed assignee requires a fresh proposal. Source chat links
retain normal room permissions; the snapshot is private audit data, not room JSON.

Cancellation/deadline expiry dismiss canonical pending approvals and append audit
events in the same transaction as stopping the reply. Completed decisions remain
intact. Existing JSON-only cards are adopted lazily under the same lock when
decided or cancelled; existing terminal cards import as receipts and cannot run
again. Missing historical harness/proposal times remain unknown. Legacy run
snapshots unavailable before this migration are marked as current-message
attribution, rather than claimed to be an original request snapshot.

Rollout requires `CreateChatApprovals` before restarting web and workers. It adds
the two approval tables and a nullable request snapshot to runs; it does not
execute or bulk-rewrite old cards. Regression tests exercise concurrent service decisions and HTTP retries, SIGKILL on both sides of commit, partial failures, canonical
argument replay, immutable audit/receipts, legacy adoption, cancellation,
permissions, requester/approver separation and source-message edits.

### AI attribution in task history

A task's History panel renders chat approvals as **AI created task**, **AI updated
task**, or **AI closed task**, with the saved execution result. Each entry shows
Requested by, Approved by, Model, Harness/version, Requested and Executed times
(including seconds and timezone), and Source chat. The source-message link opens
the exact message and thread, and is shown only when the viewer can access team
chat and that room. Task access does not grant chat access. Private, deleted or
missing sources show an unavailable label; original chat text and raw audit JSON
are never printed in task history. Missing legacy metadata says Not recorded.
Human activity keeps its existing text. This is a presentation change over the
saved approval/audit records; it requires no migration or approval replay.

### Retained approved task requests

Successful task approval notices link to the task and its saved approved request.
Task History also has a **View approved request** link. The canonical approval
retains the original message snapshot and exact approved arguments even when
the source message or room is deleted. Editing the chat later does not rewrite it.
The detail page requires access to the executed task; another task's approval
cannot be substituted. Task readers can inspect the approved change. Original
chat text is restricted to the active requester, approver, and people who currently
have access to the source chat. After room deletion only the requester and
approver retain that text access, subject to task access and tenant boundaries.
Legacy approvals without an original snapshot display **Not recorded**.

### Private assistant delivery and current permissions

Assistant requests in channels and person-to-person DMs now receive only a neutral
link to the requester's private Rupert room. The worker atomically copies the
request text into that room and queues one private reply for the selected bot.
Shared history, attachments and quoted messages are not forwarded. Retried jobs
cannot create another handoff after the source run has completed. Existing shared
history is not rewritten. New model evaluations use requester-owned private test
rooms too; old shared evaluation rooms are retained without being reused.

Each new run records the requester's permission signature. Before model recovery,
tool starts and cached-result replay, checkpoints and streamed/final writes, the
worker loads fresh requester, tenant, destination and source-room access. A
permission change, deactivation, loss of chat/dashboard access or room access
cancels the run, clears its partial reply and dismisses pending proposals. A tool
result returning after revocation cannot be checkpointed. Runs predating the
permission snapshot fail closed and must be asked again. Any permission change,
including a grant, requires a new request rather than reuse of an older transcript.
This does not retroactively erase completed conversations or change task assignees.

### Structured financial evidence

Chat no longer certifies a financial answer by finding a similar number in tool
text or conversation history. Financial tool results are converted to versioned,
private fact envelopes: exact decimal value and unit, explicit supported currency,
meaning, source, inclusive dates and timezone, tenant, tool invocation, original
field and content-derived fact ID. Those envelopes are persisted in the existing
run receipts; recovery checks their tenant, invocation and integrity.

Ruby renders financial replies directly from these facts, including the meaning,
source, period and currency. Model prose cannot relabel gross sales as profit,
substitute tax for sales, move a figure to another period or convert currencies.
Financial drafts and all numeric draft chunks are withheld from streaming.
Money uses integer cents and decimal strings, including negative and zero amounts;
there is no absolute-value or float-tolerance matching. Missing values stay unknown.

Initial contracts cover gross sales, orders, average order value, refund rate,
source shares and expense totals in `metric`; source lines and currency totals
in `sales_summary`; gross sales in `period_review`, `business_pulse` and
`time_keeping_report`; and reported/refunded/net/estimated tax by source and store
in `sales_tax_report`. Estimates are explicitly distinct from reported tax.
Currencies supported by this first two-decimal contract are USD, CAD, EUR, GBP,
AUD, NZD, CHF, CNY, HKD, SGD, MXN, BRL, ZAR and INR. Other currency conventions,
uncertified sections (including product/daily/category breakdowns and uncoded
review expenses), malformed contracts and legacy financial receipts are unavailable,
with an explanation, rather than rendered from unverified prose. No source totals
are added, currencies converted or new financial calculations performed here.
Replies contain at most twelve complete facts and explicitly disclose omissions.


## Bounded cloud generation retries

The native cloud agent may reserve one additional generation per durable run after
an explicit HTTP 429, 500, 502, 503, 504 or 529 refusal, only before any streamed chunk.
The SDK's automatic retry remains disabled when the agent supplies its remaining
whole-run budget. Network timeouts/connection failures, malformed requests, authorization
or billing errors, partially streamed responses and local model cold starts do not retry.

The default wait is half a second. A valid Retry-After delay or HTTP date is honored
only within five seconds and with at least one further second in the run budget.
Invalid or longer hints fail normally. The wait polls current permissions, cancellation,
claim ownership and deadlines. Each request is rebuilt from the durable transcript with
a fresh remaining timeout; tools from a completed round are not repeated. Reservation
is recorded before waiting and survives worker recovery, preventing a fresh allowance
on each restart. This does not imply exactly-once provider billing.

Telemetry keeps each physical provider attempt, its failed/successful outcome and nullable
usage/cost. `generation_retry_reservations` counts durable reservations, including a retry
cancelled before it starts; `provider_attempts` remains the actual observed attempt count.
`transport_retries` continues to describe SDK retries within a generation; `retry_wait`
records actual backoff duration and completion/interruption separately. No exception
messages, provider bodies, conversation text or credentials enter retry facts.

## Durable chat telemetry

`chat_telemetry` is the private operational ledger for new chat runs. It is tenant scoped,
linked to `chat_runs`, and deleted with the run. It is not part of room JSON or a model's
context. No prompt, tool arguments/results, response text, URL, credentials or exception
messages are copied into it. This is the authoritative accounting source; the older
`AiAgentRun` dashboard counters and reply metadata remain compatibility summaries and
must not be used to infer complete usage or free calls.

A successful atomic claim and its queue receipt commit together. Duplicate job deliveries
produce no claim. First claim `queue_ms` measures persisted run creation to claim; later
claim ages include prior work and are not additional queue time. Each claim has an immutable
owner token. Recovery marks that owner's unfinished spans interrupted with unknown duration;
a late completion cannot change them to success. The ledger does not infer unreported
usage from a recovered transcript, or replayed tools from their saved results.

The ledger records execution, RubyLLM generation and HTTP inference spans, time to first
received chunk (including tool-call chunks), physical provider usage attempts, tool outcomes,
replays, and classified failures. Timed spans use a monotonic clock; queue and lifecycle
boundaries use persisted wall times. An inference span includes SDK retry backoff; physical
usage events have completion timestamps, not invented individual attempt durations. Physical
attempt ordinals within a generation distinguish SDK retries from additional tool rounds and
worker recovery. Verification requests use stage `verify`. OpenCode CLI invocations and
reported step usage are separate: internal provider retries in that subprocess are unknown.

Provider-reported USD cost and CLI-reported cost are kept with their provenance, including
explicit zero. Missing cost stays null/unknown. Catalog prices are deliberately not applied
to local gateways, custom endpoints or subscriptions. Input, output, cache read/write and
thinking tokens are separate nullable counters; thinking is not added again to output.
A partially reported sum is labelled incomplete, not presented as a complete run total.
Interrupted requests and missing CLI usage also make completeness false. No retrospective
backfill guesses usage for runs created before this migration.

Operator Rails console example (use the authorized tenant context):

```ruby
run = TeamChat::Run.find_by!(message_id: message_id)
TeamChat::Telemetry.summary(run)
TeamChat::Telemetry.where(run_id: run.id).order(:id).pluck(:kind, :stage, :outcome, :duration_ms, :facts)
```

The summary includes first queue time, final run state, total lifecycle elapsed time,
reported stage durations and completeness, claim and physical attempt counts, SDK retries,
partial token totals and per-field completeness, reported USD cost and cost completeness.
Do not sum nested execution/generation/inference timings as elapsed time, or interpret
`failed_spans` (which includes nested receipts) as a count of failed replies.


## Direct page navigation

Clear, standalone page-navigation requests can be answered from `AskRupert::Guide`
without invoking a model: for example “Where are Timesheets?”, “Open Inventory”,
or “Where is stock?”. The router requires a complete supported navigation phrase
and exactly one permitted page with an exact title, registered key, singular key,
or a small allowlist of the guide's clear aliases. Generic search keywords such as
“time”, “hours” or “new” do not become navigation shortcuts. Unknown, ambiguous,
negated, mixed, threaded, quoted and attachment-bearing requests continue through the agent.
Private handoff preserves that routing restriction as a boolean without forwarding
the file, quote or shared history. Existing drafts or action cards also retain the agent path.
Explicit local agents, model comparisons and battery evaluations also continue
through their existing model path.

Private handoff happens first. Direct answers keep the same atomic claim, whole-run
deadline, cancellation and fresh permission-signature checks as model answers.
The selected page key, normalized query and router version are pinned in the private
run configuration before lookup. Recovery keeps that route even if model settings
change, re-resolves the permitted destination and verifies its actual guide link.
A previous model run cannot be reclassified, and an unsupported saved navigation
version or missing destination fails closed. The immutable original request snapshot
supplies the query; no cached answer or URL is replayed. Publication uses the ordinary
fenced terminal write, so a revoked permission, cancelled run or superseded claimant
cannot deliver the link. Read-only lookup may repeat after a crash; the reply does not.

Routing and lookup timings are recorded in `chat_telemetry`. The reply uses engine
`direct_navigation`, a null model and null token counts, with server-local answer timing.
The telemetry summary marks inference and cost `not_applicable` for this route when
no provider or CLI attempt exists. It does not fabricate provider token counts or a
reported zero price, and it creates no model-health charge record or model-score entry. The direct path
needs no model credentials and changes no model-provider configuration. Existing
`chat_runs.configuration` stores the checkpoint, so no database migration is needed.

## Assistant destination links

Model output is checked before each saved streaming draft and final reply. A GET route
alone is insufficient: page-guide destinations require current permission, record links
require the record policy and tenant, and chat files require current source-room access.
Retained approval links must match the task in the executed receipt. Unknown destinations
lose their active link while retaining the label. This does not replace controller checks
or authorize disclosure of page contents.

Same-instance absolute URLs are converted to checked relative links. Other absolute
addresses stay readable without becoming clickable; code spans remain literal. Encoded
paths, authority-relative addresses and dot segments cannot bypass destination checks.
Resumed drafts are checked before inference resumes. Each publication reloads the user;
the ordinary durable execution fence still enforces permission revocation, cancellation,
deadlines and claim ownership at the write boundary. Human messages are unaffected.

### Who answers a question that names no bot (2026-10-23)

`config/team_chat/routing.yml` (TeamChat::Router). In a room where Rupert answers everything (your Rupert room), a
question that @mentions no bot is sorted by its data guide keywords:

| Kind | Who answers | Why (battery, 2026-10-22) |
| --- | --- | --- |
| general | Qwen 4B (`qwen-4b`) | as good as Qwen 35B on single-topic questions, ~11 s, 3 GB, so it stays loaded |
| finance (books, tax, expenses, sales, order tracking) | @rupert and Qwen 4B side by side | meant to be private; side by side until Qwen 4B is trusted, then `[qwen-4b]` |
| cross (finance plus stock, people, tasks or system) | @rupert | best at joining several tools |
| "think harder", "think it through", "take your time" | Flint with thinking (`flint-think`) | best local bot on general questions, ~36 s plus a ~17 s load |

Keyword hits are counted per side (finance topics vs the rest); a question is cross only when both sides have hits and
it joins two parts ("and", "same days", "still", or one of the data guide's cross phrases), or both sides have two or
more hits; a tie stays general. Naming a bot (@qwen, @liquid, @rupert ...) always asks just that bot. Without the local
model server everything goes to @rupert. The gateway keeps `qwen3.5-4b` loaded (`--keep-loaded`); @qwen (35B) and
Flint load on demand.

### Bot lineup and rooms (2026-10-23)

The owner dropped the bots nobody asked (outside the test battery, @liquid had answered twice and the 35B @qwen
once). Now:

| Mention | Model | Notes |
| --- | --- | --- |
| `@rupert` | DeepSeek V4.1 Flash, cloud | unchanged |
| `@qwen` | Qwen3.5 4B (`qwen3.5-4b`), local | back to the 4B it was until 2026-10-22; also answers questions that name no bot |
| `@gemma` | Gemma 4 E4B, local | unchanged |

Liquid (`liquid`) and Qwen 35B (`qwen-35b`) stay on the gateway as test-only models for the battery
(`AGENT=liquid`); the battery's default bot is now `qwen`. Old replies keep their names and models.

Each person has a private room per bot besides their Rupert room: `rooms: [qwen, flint-think, gemma]` in
`config/team_chat/routing.yml`. Everything typed there goes to that bot, no @ needed. A room for a bot that is no
longer listed (or not running) is archived with its history and reopens if the bot comes back. Leftover PR
verification rooms in production were archived on 2026-10-23 (archived, not deleted).

### Suggestion bubbles (2026-10-23)

A row of six question bubbles sits above the chat box on the chat page and in the dock
(`config/team_chat/suggestions.yml`, `TeamChat::Suggestions`). Questions for the time of day come first (morning
before 11:00, afternoon, evening from 17:00), plus Monday and start-of-month ones, then the rest in an order that
changes daily per person. A tap sends the question. In a channel where bots answer only when named (#admins) the
bubble adds `@rupert `. No bubbles in direct messages between people or rooms where bots are off. Edit the YAML
and deploy to change them.

## Edited and deleted requests

Each human message has a server-owned revision counter in its private metadata.
A durable run captures that revision, exact request text, requester, parent and
request time. Editing pending work stops the old run and creates fresh replies for
the edited message under the room's normal mention/model rules; it does not post
a second human message. The replacement records the edit time as `requested_at` and gets a fresh deadline.
The full accepted current question reaches the model; history excerpt limits apply
only to older messages.
Unchanged edits and edits to completed answers without unresolved approvals do not
start inference. Removing a mention can stop work without starting another bot.

Unapproved cards are retracted when their request changes or is deleted, including
cards on a completed answer awaiting review. Completed answer text, executed
approvals, task effects and original audit snapshots are preserved. Approval also
checks the current request before executing, so a source changed outside the normal
editor cannot authorize an old proposal. Already decided receipts remain idempotent.
Pending proposals without a verifiable durable request require a fresh proposal.

The edit, cancellation, retraction and replacement commit atomically. Rate-limit
failure rolls them back together. Oversized edits are rejected rather than truncated. Replacement jobs enqueue only after the outer
transaction commits; the existing recovery sweep can dispatch a committed queued
run if enqueueing was interrupted. Superseded jobs cannot claim their cancelled
runs. Deleting a request stops work without creating a replacement.

Workers recheck revision, text, author, tenant and thread before tools, publication
and checkpoints, including recovery and direct navigation. Private handoffs retain
only source identity/revision/time, not shared history or attachment content; editing
or deleting the original source also stops its private work. Legacy handoffs lacking
source identity stop rather than resume an unverifiable request. Edit timestamps also reject source changes newer than run creation when an external
writer leaves the counter unchanged, including legacy snapshots. The existing permission,
cancellation, ownership and deadline fences continue to apply.

An edit response includes the stopped and new messages from that same room so the
existing chat renderer updates immediately; private handoff messages never enter a
shared room's response. A replacement can know that a previous revision already had
an approved effect, but previous tool results are not copied into its context. It
must inspect current state with permitted tools before proposing further work.
