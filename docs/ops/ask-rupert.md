# Ask Rupert: the in-app help chat

Added 2026-10-22. A speech-bubble button beside Rupert's face in the header opens **Ask Rupert**, a side panel where people ask how to do things, where things are, and questions about data they are allowed to see. When it cannot help it offers to hand the chat to the Rupert team as a report.

It is a help assistant, not an operator: it changes nothing in Rupert except a report that the person presses **Send** themselves.

## What people see

- **Header button** (`Ask`, a speech bubble beside Rupert's face) and a right-hand panel. Full width on a phone; on screens 1000px or wider it expands into a history rail beside the conversation. Light and dark follow the account's Appearance setting.
- A one-line disclosure at the top says where answers come from (cloud model, local model, or both) and what leaves the server.
- Starter questions on an empty chat, chosen from what the person can actually do. **New chat** starts a fresh conversation; **Clear** deletes the current one. **History** (also *Ask Rupert chats* in the account menu) lists the person's saved chats to reopen.
- Replies grow on screen while they are written (the page polls the conversation every second or so). Answers carry links into Rupert and the matching Learn Rupert lesson when one exists.
- **Report it to the Rupert team** is always at the foot. The model can also prepare a draft report; the person reads it, edits it and presses **Send report**. Nothing is filed by the model.
- Available to people with the **Rupert Chat** permission (`chat.use`): administrators by default, and it can be given to other roles or people on the Permissions screen. Not available to the employee app or in customer-support views.

## How an answer is made

1. `AskRupert::Guide` looks the question up in the **real navigation** (`ModuleRegistry.nav_for`) and the **real lesson catalog** (`LearningCatalog.available`), both filtered to what that person may open. The best matches go into the prompt as context. Pages that exist but are not theirs are named without a link ("ask an administrator").
2. `AskRupert::Brain` sends the context plus the recent conversation to a model. The model has **no tools of its own**. It may answer, or emit one line `TOOL_CALL: {"name": ..., "arguments": {...}}`; Rupert checks it, runs it, and feeds the result back as data. At most three tool calls per question.
3. Tools (`AskRupert::Tools`) run **in-process as the signed-in person**, never with a stored or broad token:

| Tool | Offered when | What it does |
| --- | --- | --- |
| `where_is` | always | Pages and menus for a topic, with links. |
| `how_do_i` | always | Lessons (with steps) and definitions. |
| `search` | `dashboard.read` | `SearchService`, which already checks each category's permission. Emails and phone numbers are removed before the model sees results. |
<<<<<<< HEAD
| `run_report` | at least one report scope | Runs one of the read-only MCP tools (`sales_summary`, `sales_tax_report`, `inventory_search`, `stock_comparison`, `swipesimple_items`, `time_keeping_report`, `list_tasks`, `list_alerts`, `list_reports`, `history_summary`) through `AskRupert::ScopedToken`, an in-memory stand-in for an API token built from the person's current permissions. It never carries a write scope and is not stored. |
=======
| `run_report` | at least one report scope | Runs one of the read-only MCP tools (`sales_summary`, `sales_tax_report`, `inventory_search`, `stock_comparison`, `swipesimple_items`, `time_keeping_report`, `list_tasks`, `list_alerts`, `list_reports`, `list_uploads`) through `AskRupert::ScopedToken`, an in-memory stand-in for an API token built from the person's current permissions. It never carries a write scope and is not stored. |
>>>>>>> claude/quickbooks-import
| `system_status` | always (sections vary) | Build for everyone; last sync with `sync.read`; update availability for update managers; last backup for platform administrators. |
| `file_report` | always | Prepares a **draft** report only. |

Every tool call is written to the Activity log (`ask_rupert_tool`) with the tool name, outcome, duration and conversation id. Never the question, arguments or result.

## Which model answers

Mode is set per workspace on **System → Ask Rupert usage**:

| Mode | Behaviour |
| --- | --- |
| Cloud model (default) | `opencode run --agent chat --pure` (the same CLI and tool-less `chat` agent the @rupert Buzz agent uses; model from `OPENCODE_MODEL`, default `deepseek-v4-flash`). |
| Local first, cloud as backup | Short how-to or where-is questions go to a local Ollama model; anything with numbers or data words, or a local failure, goes to the cloud. |
| Local only | Only the local model. Nothing leaves the server. If it is not configured or is down, people get a friendly "can't reach the assistant" message. |

Instance configuration (environment, not editable by workspace administrators):

| Variable | Meaning |
| --- | --- |
| `OPENCODE_MODEL` | Cloud model id shown in the disclosure and recorded in usage. Default `deepseek-v4-flash`. |
| `ASK_RUPERT_OPENCODE_BIN` / `ASK_RUPERT_OPENCODE_AGENT` | The CLI binary (default `opencode`) and its tool-less agent (default `chat`). The web and job processes must be able to run it, the same way the Buzz agent does. |
| `OLLAMA_URL`, `ASK_RUPERT_LOCAL_MODEL` | Local model server and model name (Gemma 4 is the baseline being evaluated). Both must be set for the local modes to work. |
| `ASK_RUPERT_RATE_LIMIT`, `ASK_RUPERT_DAILY_CAP`, `ASK_RUPERT_MODE` | Optional defaults for the limits and mode; a saved workspace setting wins. |

Replies are written by a job (`AskRupertReplyJob`), so a slow model never holds a web request. In development the job runs in the background so the streaming can be seen.

## Light abuse limiting

No lockouts, bans or captchas. Defaults, all adjustable by someone with settings-write (bounded so they cannot be set to nothing or to unlimited):

- 20 questions per 10 minutes and 200 per 24 hours, per person.
- One reply in flight per person. A reply stuck for 3 minutes is marked failed and stops counting.
- 1,000 characters per question; the model sees the last 12 turns up to 8,000 characters.
- Over a limit the person gets a friendly message with how long to wait (HTTP 429 with `Retry-After`). Failed replies and refused attempts do not count against anyone.

Counts live in `ask_rupert_usages` (counters only: person, time, provider, model, tokens, number of lookups). They survive **Clear**, so clearing a chat does not reset a limit, and are kept 35 days. **System → Ask Rupert usage** shows last-7-day totals, per-person counts and tokens, and the settings. When the AI-health tables are present (`AiAgentRun`), each cloud reply also records its tokens there under `agent = 'ask_rupert'`.

## Safety

- Everything from people, pages and records is untrusted. Tool results are wrapped as data; text that looks like a tool call inside them is never executed because only the model's own output is parsed.
- Permissions are decided by the server, not the prompt: tools the person lacks are not offered and are refused again when called; each tool re-checks.
- Typed text and tool results pass through `AskRupert::Redactor` (API keys, bearer tokens, card-like numbers; emails and phone numbers in tool results) before reaching any model.
- Replies are rendered as text in the browser with a small Markdown subset (paragraphs, lists, bold, code and **same-site** links). HTML is never parsed, and links to other sites are shown as plain text.
- A conversation is private to its owner and workspace. **Clear** deletes it and its messages. Chats are saved until their owner clears them. A workspace can set a retention window in days (usage page) and `AskRupertRetentionJob` (nightly) then deletes older chats; the default is to keep them.
- The report attaches the last 12 turns of the chat (secrets removed) to the feedback row. It is visible only to people who review feedback.

## Operating notes

- Turn it off for a workspace with the checkbox on the usage page, or take **Rupert Chat** away from a role. The header button and its endpoints disappear for whoever lacks it.
- Sharing a chat with others and group chats are not built in Rupert. Buzz already does group conversation. A first, help-only version of Ask Rupert in Buzz exists (below); the design for the rest is in `buzz-ask-rupert-design.md`.
- If answers stop, check **System → Ask Rupert usage** for failed replies, then the opencode CLI and its key on the host (the AI-health page, when present, shows the provider state).
- Deleting a user does not delete usage counters; the retention job removes them after 35 days.
- Routes: `GET /ask_rupert.json`, `POST /ask_rupert/conversations`, `GET /ask_rupert/conversations` (history), `GET|DELETE /ask_rupert/conversations/:id`, `POST …/messages`, `POST …/report`, `GET|PATCH /ask_rupert/usage`.

## In Buzz (off by default)

An administrator can let the `@rupert` agent in Buzz answer linked people with the same help, from **System → Ask Rupert usage → Let the @rupert agent in Buzz answer linked people**. Restart the agent after changing it. Nothing changes while it is off.

- **Linking** (Buzz page → *Link your Buzz account*): the person makes a one-time code in Rupert (10 minutes, only its digest is stored), sends `link CODE` to `@rupert` in a **direct message**, then confirms the public key (shown as an `npub`) back in Rupert. Both steps are needed. A code posted in a channel is refused and burned. The key comes from the signed Nostr event, never from anything typed or any name. Links are checked on every message: a person who is deactivated, an employee-app account, or without Rupert Chat stops being answered at once. Linking, confirming, removing and refused attempts are in the Activity log (first 8 characters of the key only).
- **What the agent does there:** in a direct message and when mentioned in any channel it has been added to, it answers a linked person from their own pages and Learn Rupert lessons (`AskRupert::HelpBrain`), through the same model settings, disclosure, redaction and per-person limits as the panel. **Only `where_is` and `how_do_i` exist in Buzz.** `search`, `run_report`, `system_status` and `file_report` are never offered there, and are refused if the model asks, because Rupert cannot know who else reads a channel or how long the Buzz relay keeps it. In a room, pages a person lacks are not mentioned. Replies show the page title and its full address (`RUPERT_PUBLIC_ORIGIN`, else `HOST`).
- **Unlinked people** get one hint (at most once every 30 minutes per channel) and nothing else outside the team channel.
- **The team channel** (`BUZZ_CHANNEL`) behaves as before for everyone, including the operations snapshot it already showed; only link codes are handled differently there.
- **Storage:** nothing is saved in Rupert for these answers except the usage counters (they share the panel's limits). The Buzz relay keeps what people write, and Rupert cannot clear it.
- **Channels:** with the switch on the agent also learns which channels and direct messages it is in from the relay's member lists, and keeps what was said per channel, so a direct message never reaches another channel's prompt. A conversation counts as private only when the member list says it is the agent and exactly that sender.
- **Not verified:** no live relay was available; the subscription to member lists and add notices follows Buzz's `NOSTR.md` and is covered by tests with the relay stubbed.
