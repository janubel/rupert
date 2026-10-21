# Bug and request reports (the ladybug)

Any signed-in staff member can report a bug, ask for something or ask a question
from any page. Each report becomes a task for the store owner, and connected AI
assistants and the `@rupert` chat agent file and read reports through the same
records. This page describes the whole feature; the sections for pieces that
have not shipped yet say so.

## What staff see

- A ladybug button in the header (next to Help) opens the report panel
  (shipping in the "ladybug panel" change).
- **My reports** (`/feedback_reports`) lists the reports you sent and each one's
  status: New, Triaged, Planned, Done or Won't fix. Open a report to read what you
  sent. You never see other people's reports, owner notes or attachments.
- Everyone who can sign in may file a report, including time-clock-only staff
  accounts. There is no permission to grant.

## What is attached

When a report is sent, the browser adds (staff can see this list in the panel):

| Attachment | Source | Notes |
| --- | --- | --- |
| Screenshot | the panel, via a vendored `html2canvas-pro` | PNG or JPEG, at most 1.5 MB, optional |
| Page snapshot | the panel | HTML of the page with scripts removed and password / card / token fields blanked |
| Browser details | the panel | viewport, screen, theme, language, time zone, user agent, page address, build revision, request IDs |
| Recent JavaScript errors | the panel | the last 10 errors since the page loaded |
| Server log lines | the server | log lines of the session's last 12 requests, run through the log filter |
| SQL queries | the server | queries of the same requests with every literal value replaced by `?` |

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
