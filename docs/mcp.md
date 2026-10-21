# Rupert MCP server for AI assistants

Rupert has a built-in [Model Context Protocol](https://modelcontextprotocol.io)
(MCP) server, so AI assistants such as Claude Code, Claude Desktop, ChatGPT or
any other MCP client can read Rupert's data and report back what worked and what
did not. It uses the same bearer tokens, scopes and owner permissions as the
[read API](api-v1.md): an assistant can never see more than the token allows.

- Endpoint: `POST https://<your-rupert-host>/mcp`
- Transport: Streamable HTTP, JSON-RPC 2.0, plain JSON responses (no SSE stream,
  no session). `GET /mcp` returns `405`.
- Protocol versions: `2025-06-18` (preferred), `2025-03-26`, `2024-11-05`.
- Nothing writes to Shopify, Square, C-Trax or SwipeSimple. The only tools that
  change anything are `submit_feedback` (stores feedback and, when asked, opens a
  review task) and `create_task` (adds a task to Rupert's own Tasks board, only
  with the `tasks:write` scope). The operations and report tools below are
  read-only.

## 1. Create a token

An operator with `settings.write` opens **System → API access**, names the token
after the assistant (e.g. "Claude — bookkeeping helper"), selects only the scopes
it needs, sets an expiry and copies the token. The full secret is shown once.
Treat it like a password: put it in the client's secret store or an environment
variable, never in a chat message, a shared config file or Git.

The owner's *current* permissions are checked on every call, so removing a
permission from the token's owner immediately hides the matching tools. Revoking
the token on the same page stops it on the next request.

## 2. Connect a client

### Claude Code

```sh
claude mcp add --transport http rupert https://<host>/mcp \
  --header "Authorization: Bearer $RUPERT_MCP_TOKEN"
```

Then ask Claude something like "Using Rupert, what was sales tax last month?".
`claude mcp list` shows whether the connection works.

### Claude Desktop

Claude Desktop's built-in custom connectors expect OAuth, which Rupert does not
offer yet. Use the `mcp-remote` bridge with the bearer header instead, in
`claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "rupert": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://<host>/mcp", "--header", "Authorization:${RUPERT_AUTH}"],
      "env": { "RUPERT_AUTH": "Bearer rupert_..." }
    }
  }
}
```

(`Authorization:${RUPERT_AUTH}` has no space after the colon because some
clients split arguments on spaces.)

### Other clients (ChatGPT, Cursor, VS Code, custom agents)

Any MCP client that supports Streamable HTTP with a custom header works: set the
URL to `https://<host>/mcp` and add the header
`Authorization: Bearer <token>`. Clients that only support OAuth-based remote
connectors can use `mcp-remote` as above.

Raw example:

```sh
curl -s https://<host>/mcp \
  -H "Authorization: Bearer $RUPERT_MCP_TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_workspace_info","arguments":{}}}'
```

> **Also used inside Rupert.** The in-app help chat, [Ask Rupert](ops/ask-rupert.md), runs
> the read-only tools below in-process as the signed-in person (never with a stored token and
> never with a write scope). Its scopes come from that person's current permissions, so it
> shows no more than the same person would get from a token with those scopes.

## 3. Tools

`tools/list` only returns the tools the token may use. Every tool is read-only
unless marked.

| Tool | Scope needed | Owner permission | What it does |
| --- | --- | --- | --- |
| `get_workspace_info` | any valid token | — | Store, time zone, today, token scopes, available and locked tools. Start here. |
| `submit_feedback` | any valid token | — | **Writes feedback only.** Report a bug, struggle, task outcome, suggestion, question or report issue. |
| `list_my_feedback` | any valid token | — | Status of feedback this token sent (never the owner's notes). |
| `list_reports` | `reports:read` | `reports.read` | Rupert's reports, their pages and the tool that answers each. |
| `sales_summary` | `reports:read` | `reports.read` | Orders and gross sales per source and currency, optional daily series and top products. |
| `sales_tax_report` | `reports:read` | `reports.read` | Tax per source and store (Shopify, Square, Rupert POS, C-Trax, SwipeSimple); labelled estimates. |
| `inventory_search` | `inventory:read` | `inventory.read` | Mirrored Shopify/Square stock per item and location. |
| `stock_comparison` | `inventory:read` | `inventory.read` | Shopify vs C-Trax stock side by side, with issues. |
| `swipesimple_items` | `inventory:read` | `inventory.read` | SwipeSimple item list matched to Shopify, Square and C-Trax. |
| `time_keeping_report` | `timesheets:read` | `timesheets.read` | Scheduled vs worked hours (own hours only unless the owner reviews timesheets). |
| `list_tasks` | `tasks:read` | `projects.read` | Tasks board, most urgent first. |
| `create_task` | `tasks:write` | `projects.write` | **Writes:** adds a task to Rupert's own Tasks board, marked as added by an AI assistant. |
| `list_alerts` | `alerts:read` | `alerts.read` | Low-stock alerts with counts per status. |
| `ai_health` | `system:read` | `system.read` + instance operator | Health of the opencode integration behind the @rupert Buzz agent: key state, live free models, agent model status, tokens in/out today and over 7 days, rate-limit hits, warnings. Counts only — never the key or message content. Hidden from tokens whose owner is not a platform administrator. See [AI health monitor](ops/ai-health-monitor.md). |
| `instance_status` | `system:read` | `system.read` | Is Rupert healthy: build, uptime, the four readiness checks (database, queue worker, last sync, disk) and workspace counts. |
| `recent_errors` | `system:read` | `system.read` | Recent failed source syncs and the MCP tools that fail most (this store); with a platform administrator owner also process error lines and failed background jobs (class and error only). Text is scrubbed. |
| `sync_health` | `system:read` | `system.read` | Per source and operation: latest attempt, failure category, last success; latest catalog run; queue worker heartbeat. |
| `backup_freshness` | `system:read` | `system.read` | Latest verified Drive backup and its age, newest local snapshot files (names and ages only). Platform administrator or private workspace owner only. |
| `deploy_status` | `system:read` | `system.read` | What the host auto-deployer last reported (`/var/lib/rupert-autodeploy/status.json`, `last-deploy.json`) next to the running build. Platform administrator or private workspace owner only; empty where the deployer is not installed. |
| `list_feedback` | `feedback:read` | `settings.read` | Every report and piece of feedback in the store (ladybug, Buzz, assistants): status, severity, source, task, ready-for-development flag. Administrator owner only. |
| `report_context` | `feedback:read` | `settings.read` | One report with its attachments: browser details, JavaScript errors, server log lines, SQL queries (literals removed), page snapshot, screenshot metadata. Administrator owner only. |

The operations tools share the `system:read` scope with `ai_health`, and the
report tools use `feedback:read`. Both follow the same rule as the others: the
token's owner must hold the permission (`system.read`, `settings.read`) now, and `report_context` / `list_feedback`
additionally require the owner to be a store administrator because attachments
can contain page contents. Server-wide facts (process errors, failed jobs, backups,
the deployer) are shown only when the owner is a platform administrator or the
workspace is a private single-store node (`RUPERT_NODE_MODE=workspace`).

Conventions every tool follows (also in the `rupert://guide/getting-started`
resource):

- Dates are ISO `YYYY-MM-DD` in the store's time zone; ranges are inclusive.
- Money is integer cents. `null` means unknown/not reported, never zero.
- Sources (Shopify, Square, Rupert POS, C-Trax, SwipeSimple) are never added
  together unless the tool says the total is safe.
- Lists are paginated: `page` and `per_page` (max 50); follow `meta.next_page`
  while `meta.has_more` is true. Results over 200 KB are refused with a hint to
  narrow the request.
- Each result has a short text summary plus the same data as JSON
  (`structuredContent`). Tools carry `readOnlyHint` annotations.

Errors: protocol problems return JSON-RPC errors (`-32700` bad JSON, `-32600`
invalid request, `-32601` unknown method, `-32602` bad params or unknown tool).
Tool problems — a denied scope, invalid arguments, a record that does not exist —
come back as a normal result with `isError: true` and a plain-language
explanation the assistant can act on.

Resources: `resources/list` offers `rupert://guide/getting-started` (data
conventions and how to send feedback) and `rupert://guide/tools` (tools for this
token and the scopes that unlock the rest).

## 4. Feedback from assistants

Rupert asks connected assistants to call `submit_feedback` whenever a tool
confuses them, fails, returns something that looks wrong, or when they finish a
task. Arguments:

| Field | Required | Notes |
| --- | --- | --- |
| `kind` | yes | `bug`, `struggle`, `task_report`, `suggestion`, `question`, `report_issue`, `request`, `direction` |
| `summary` | yes | ≤200 characters |
| `details` | no | ≤5000 characters |
| `related_tool`, `related_reference` | no | Tool name; Rupert page, report or record |
| `severity` | no | `low`, `normal` (default), `high` |
| `agent_name`, `agent_model` | no | e.g. "Claude Code", model name |
| `context` | no | Small JSON object, ≤4000 bytes |
| `open_task` | no | `true` also opens a task in the **Rupert Feedback** project for the owner to review (bug, request, direction, suggestion and question kinds) |
| `source`, `source_ref`, `source_sender` | no | Where it came from: `source` is `agent` (default) or `buzz`; `source_ref` is the chat message id (the same message is filed only once); `source_sender` is the sender's Nostr public key |
| `ready_for_development` | no | Requests "ready for development". Honoured only when the token has `tasks:write` **and** `source_sender` is on the owner's allow-list (Settings → Environment, `FEEDBACK_READY_SENDERS`); otherwise the report is still created, for review, and the reply says so |

Feedback is stored per store with the token and its owner, status `new`. Each
token may send 200 items per 24 hours. Reports made with the ladybug in Rupert and
by the `@rupert` chat agent land in the same list (`source` `app` / `buzz`); see
[docs/ops/feedback-reports.md](ops/feedback-reports.md). Read them back with
`list_feedback` and `report_context`.

Rupert also records a struggle signal automatically: every failed or denied tool
call increments a counter per tool and error type (denied, invalid arguments,
unknown tool, not found, tool error, unexpected failure). Arguments are never
stored.

The owner reviews both under **System → AI assistant feedback** (`/ai_feedback`):
`settings.read` to view, `settings.write` to set the status (new, triaged,
planned, done, won't fix) and add notes. The page filters by kind, status,
severity and tool, shows counts and tool-error statistics, and exports CSV.
Assistants can see their own items' status with `list_my_feedback`, never the
owner's notes.

Feedback text is written by an AI and is **untrusted**: Rupert stores it
length-capped with control characters removed, shows it escaped, protects the CSV
against spreadsheet formulas, and never follows instructions inside it.

## 5. Rate limits

- `mcp/token`: 120 requests per minute per token.
- `mcp/ip`: 30 requests per minute per IP for requests without a token.
- The global 600 requests per minute per IP ceiling also applies.

Exceeding a limit returns `429` with `Retry-After`.

## 6. Security notes

- The MCP controller reads at most 256 KiB + 1 bytes from Rack input before
  JSON parsing and returns `413` above the limit. Rack may already have buffered
  or limited the body; upstream proxy request limits are still needed to bound
  streaming and memory use.
- Report text, attachments and chat messages are untrusted: the tool descriptions
  say so, and nothing in them can mark work ready for development, deploy or
  change data.
- Tokens are tenant-scoped; the host name, cookies and request body cannot
  change the store. Only SHA256 digests are stored.
- Browser requests with an `Origin` header from another site are refused with
  `403` (DNS-rebinding protection). Extra trusted origins can be listed in the
  `MCP_ALLOWED_ORIGINS` environment variable (comma separated). Clients that do
  not send `Origin` (CLIs, desktop apps, servers) are unaffected.
- No browser session is used and there is no CSRF exposure: the bearer header
  is the only credential.
- Every tool call is written to the Activity log (`mcp_tool_call`) with the tool
  name, token id, outcome and duration — never arguments or results.
- Give each assistant its own token with the fewest scopes, an expiry, and
  revoke it when it is no longer used. A token cannot be issued with a scope its
  owner lacks, and employee (staff self-service) accounts cannot own tokens.
- An assistant acting through Rupert can still be steered by text it reads
  (task descriptions, feedback, product names). Rupert's tools are read-only
  apart from feedback and the opt-in `create_task`, which limits what such
  prompt injection could change.
