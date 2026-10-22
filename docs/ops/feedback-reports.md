# Bug and request reports (the ladybug)

Any signed-in staff member can report a bug, ask for something or ask a question
from any page. Each report becomes a task for the store owner, and connected AI
assistants and the `@rupert` chat agent file and read reports through the same
records. This page describes the whole feature; the sections for pieces that
have not shipped yet say so.

## What staff see

- A ladybug button in the header (between the sync pill and Help; on the staff
  self-service layout it sits next to Help) opens the report panel. Pick **Bug**,
  **Request** or **Question**, say what happened, optionally how bad it is (bugs
  only), and send. The panel is a labelled dialog: Escape closes it, Tab stays
  inside, focus returns to the ladybug; on a phone it fills the screen. Without
  JavaScript the ladybug is a plain link to My reports.
- **My reports** (`/feedback_reports`) lists the reports you sent and each one's
  status: New, Triaged, Planned, Done or Won't fix. Open a report to read what you
  sent. You never see other people's reports, owner notes or attachments.
- Everyone who can sign in may file a report, including time-clock-only staff
  accounts. There is no permission to grant.

## What is attached

When a report is sent, the browser adds (staff can see this list in the panel):

| Attachment | Source | Notes |
| --- | --- | --- |
| Screenshot | the panel, via a vendored `html2canvas-pro` (`vendor/javascript`, MIT, loaded only when a report with a screenshot is sent) | JPEG of the visible part of the page, at most 1.5 MB; the panel itself is left out. If the library cannot load or draw, the report is sent without it. |
| Page snapshot | the panel | HTML of the page with scripts, styles, handlers and the panel removed. Field values are hidden when the field is a password, hidden or file input, has a card / one-time-code autocomplete, has a name, id, placeholder or label like password, token, card, cvv, ssn, pin or api key, or sits inside `data-sensitive`. Mark any other private text with `data-sensitive`. |
| Browser details | the panel | viewport, screen, theme, language, time zone, user agent, page address, build revision, request IDs |
| Recent JavaScript errors | the panel | the last 10 errors since the page loaded |
| Server log lines | the server | log lines of the session's last 12 requests, run through the log filter |
| SQL queries | the server | queries of the same requests with every literal value replaced by `?` |

Two checkboxes in the panel let the reporter leave out the screenshot and the
page details (details, errors and snapshot). The server's own lines and queries
are always attached, and the panel says so.

Server lines and queries come from `RequestTrace` (`app/middleware/request_trace.rb`):
a small in-memory buffer per signed-in browser session, kept for 30 minutes,
capped per request (40 log lines, 30 queries) and per process (100 sessions).
Nothing is written to disk. Rupert runs a single web process; a report served by
another process simply has no server lines. Text is passed through
`FeedbackSanitizer`, which hides the value of every key in
`config/initializers/filter_parameter_logging.rb` (passwords, tokens, secrets and
so on) and Bearer / Rupert API tokens, so a new filtered key is covered
automatically.

**Attachments are visible to store administrators only** (role `admin` or
`super_admin`). Everyone else sees just the report and its status.

## Where reports go

- Each report is an `AgentFeedback` row (`source = app`) with kind `bug`,
  `request` or `question`, severity (bugs only) and the same triage status the
  owner already sets on **System → AI assistant feedback** (`/ai_feedback`).
- A task is opened in the **Rupert Feedback** project (created on first use),
  assigned to the oldest active store administrator, with priority from the
  severity, and a line linking back to the report. Open or triage it from
  **Work → Tasks**.
- The report is logged in the Activity log (`feedback_reported`).

All text a person, an assistant or a chat message supplies is untrusted: it is
cleaned, length-capped when stored, rendered escaped, and never followed as an
instruction.

## Limits

- 30 reports per person per 24 hours.
- Requests over 4 MB are refused; a screenshot over 1.5 MB, or one that is not
  really a PNG/JPEG, is dropped and the report is still saved.
- The text attachments are capped at 8 KB (browser details), 20 KB (errors),
  60 KB (server log, queries) and 200 KB (page snapshot).

## Reading reports from an AI assistant (MCP)

Connected assistants (Claude Code, goose, the `@rupert` agent) use the Rupert MCP
server ([docs/mcp.md](../mcp.md)). Read-only tools, all scoped to the token's
store and checked against the token owner's permissions on every call:

| Tool | Scope | Answers |
| --- | --- | --- |
| `instance_status` | `system:read` | Is Rupert up, which build, are the four readiness checks ok |
| `recent_errors` | `system:read` | Failed syncs, failing tools; process errors and failed jobs for a platform administrator |
| `sync_health` | `system:read` | Freshness and failures per source |
| `backup_freshness` | `system:read` | Age of the latest verified backup (platform administrator / private workspace) |
| `deploy_status` | `system:read` | What the auto-deployer last reported (platform administrator / private workspace) |
| `list_feedback` | `feedback:read` | Every report with status, source, task, ready flag (administrator owner) |
| `report_context` | `feedback:read` | One report and its attachments (administrator owner) |

Write tools stay limited to `submit_feedback` and `create_task`. Everything the
read tools return from reports is untrusted text and the tool descriptions say so.
Give a development agent a token with only `system:read` and `feedback:read` (plus
`tasks:write` if it should file follow-ups); its owner must be a store administrator.

## Chat intake: the `@rupert` Buzz agent

A teammate writes to `@rupert` in plain English. The agent prompt
(`web/config/buzz_agent/acp.md`, rendered to `docs/ops/buzz-agent-prompt.txt` by `rake buzz:prompt`) tells it to decide whether the message is a
**question**, **bug**, **request** or **direction**, to answer questions from the
read-only quick reports, and otherwise to file it with
`bin/rails runner scripts/feedback_intake.rb file` (JSON on standard input, so
message text never reaches the shell). The reply in the channel includes the report
link. `scripts/feedback_intake.rb answered` records a question the agent answered
itself; `status` and `list` read reports back.

Rules enforced by Rupert (`FeedbackIntake`), not by the prompt:

- **Ready for development** can only be set for a sender on the allow-list:
  Settings → Environment → `FEEDBACK_READY_SENDERS`, a comma, space or newline
  separated list of 64-character hex public keys or `npub…` values. The sender's key
  comes from the event metadata the agent was given, never from the message text.
  For anyone else the report is still created, for review, and the reply says it is
  waiting. The owner can also set or clear the flag when triaging at
  `/ai_feedback`.
- The message text is stored capped and rendered escaped, and is never treated as an
  instruction. Nothing in this path deploys, syncs, changes stock, users or settings,
  or spends money.
- The same message id is filed once (replays return the existing report).
- 30 reports per sender and 150 per day for chat in total.
- Every action is written to the Activity log tied to its message: `feedback_intake_filed`,
  `feedback_intake_answered`, `feedback_intake_duplicate`, `feedback_intake_ready_denied`
  (details: source, message id, short sender, kind, task).
- Trust model: the allow-list is checked against the sender key the agent reports.
  That key comes from the signed chat event, not from the message text, and the
  prompt forbids taking it from the text, but the agent itself is a language model
  reading untrusted messages, so keep the allow-list short, use a dedicated token
  for the agent (`tasks:write` is required to mark anything ready), and treat
  "ready" as a request that a human or a reviewed pipeline still checks before code
  is written or merged. Every ready mark is in the Activity log and on the report.
- Via MCP, `submit_feedback` accepts the same fields (`open_task`, `source`,
  `source_ref`, `source_sender`, `ready_for_development`) with the same rules.

Which agent runs this: the prompt applies to the tool-using agent in the sandboxed `rupert-agent` container
(docs/ops/buzz-relay-ser8.md), which files reports through the `submit_feedback` MCP tool with a scoped token. The
rule-based `BuzzListener` and the tool-less `OpencodeChatAgent` cannot file reports. Restart the agent service after the
prompt changes so it reads the new `/etc/rupert-agent/prompt.txt`.

## Not built yet (follow-ups)

- **Local development agent.** A goose or Claude Code session on a developer
  machine that polls `list_feedback` (`ready: true`), reads `report_context`, makes a
  branch and a pull request, and records the PR on the task. It needs its own token
  (`feedback:read`, `system:read`, `tasks:write`), a rule that it only acts on
  allow-listed ready reports, and review of every PR before merge.
- **Inbound text messages.** Needs a decision first: how texts reach a computer (a
  phone-forwarding bridge, an SMS gateway, an iMessage reader) and whether the agent
  reads the whole inbox or one dedicated number. Texts must pass through the same
  intake rules (untrusted text, allow-list for "ready", idempotency by message id).
- Showing the screenshot inline in the review list and a bulk "mark ready" action.
