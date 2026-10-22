# Logging, errors and retention

Rupert writes **one JSON object per line** to standard output. On SER8 that is journald
(`journalctl -u rupert-web`, `-u rupert-jobs`). In development you get Rails' readable log
plus the same events as `name key=value` text.

What was wrong on 2026-10-21 (audit of SER8, read-only): about 93,000 lines in three days and a
955 MB journal with no cap; three plain-text lines per request with only a request id; no user,
tenant, role or response size; nothing saying *why* a form returned 422 or a permission was
refused; and a log dominated by `GET /` and `GET /login` every 30 s, `POST /internal/workspaces/claim`
every 15 s and `/up` probes. A 51 MB `log/test.log` sat in the production directory.

## What a request line looks like

```json
{"ts":"2026-10-21T22:37:08.724Z","level":"warn","event":"request","request_id":"6b75f3fc-0875-48a6-84f1-021f473f6e23",
 "method":"POST","path":"/bank_statements","route":"/bank_statements(.:format)","controller":"bank_statements","action":"create",
 "format":"html","status":422,"duration_ms":32.5,"db_ms":1.8,"view_ms":18.5,"allocations":17454,"bytes":67162,
 "user_id":5,"tenant_id":"herbal-healers","role":"admin","ip":"192.168.3.1","params":["account_label","file"]}
```

Every request that reaches the app gets exactly one such line, including 404s, blocked hosts and
requests that never find a controller. Fields: `request_id` (also the `X-Request-Id` response header), `method`, `path` (no query; token-looking segments become `:token`), `route`
(the pattern, e.g. `/orders/:id`), `controller`, `action`, `format`, `status`, `duration_ms`,
`db_ms`, `view_ms`, `allocations`, `bytes` (response size), `user_id`, `tenant_id`, `role`, `ip`,
`query_keys` (names only), `params` (names of the submitted parameters only, numeric keys shown as
`#`), `location` (where a redirect went, path only), `slow` and, for failures, `error_class`,
`error_message` (redacted) and `error_at` (the first application stack frames).

`level` is `error` for 5xx, `warn` for 4xx other than 404 and for slow requests, `info` otherwise.

## Events

| `event` | Level | Fields (never values) | Written when |
| --- | --- | --- | --- |
| `request` | info / warn / error | see above | every request |
| `auth` | info; warn on failure | `source` (password, google, logout), `status`, `reason`, `user_id`, `email_hash` (12 hex characters of a SHA-256, only when the user is unknown), `ip` | each sign-in, failure and sign-out (the same call that writes the Access log) |
| `permission_denied` | warn | `controller`, `action`, `via` (`pundit`, `status_403`, `flash`), `policy`, `query`, `user_id`, `role` | a Pundit refusal, a 403, or a "no permission" notice |
| `validation_failed` | warn | `model`, `fields` (attribute names), `kinds` (`blank`, `taken`, `inclusion`, … or `custom`), `errors`, `controller`, `action` | a form re-rendered with model errors |
| `upload` | info; warn if rejected | `files` (`param`, `ext`, `size`, `declared_type`, `type_guess`, `type_matches`, `sha256`), `outcome` | any request carrying an uploaded file; never the name or contents |
| `import` | info; warn if rejected | `kind`, `outcome`, `rows`, `duplicates`, `document_id`, `error_class` | bank statement, SwipeSimple, IRIS imports |
| `sync` | info; error on failure | `source`, `operation`, `outcome`, `duration_ms`, `category`, `job_id` | each sync run (SyncAttempt row stays the durable record) |
| `job` | info; error on failure | `job_class`, `queue`, `job_id`, `executions`, `duration_ms`, `db_ms`, `outcome`, `error_class` | each job run that failed or took ≥ 1 s; quick successes are counted in `noise_summary` |
| `job_retry`, `job_retry_exhausted`, `job_discarded` | warn / error | job fields, `wait_s` | retry and discard handling |
| `exception` | warn if handled, error if not | `error_class`, `error_message`, `error_at` (12 frames), `handled`, `source`, `context_keys` | every `Rails.error.report` |
| `mcp_tool_call` | info; warn if refused | `tool`, `token_id`, `outcome`, `duration_ms` | each MCP tool call; no arguments or results |
| `ask_rupert`, `ask_rupert_tool` | info / warn | `outcome`, `provider`, `model`, token counts, `tool`, `duration_ms` | each Ask Rupert reply and tool call; no message text |
| `rate_limited` | warn | `rule`, `method`, `path`, `ip` | Rack::Attack throttled a request |
| `db.migrate` | info / error | `phase`, `pending`, `from_version`, `to_version`, `applied`, `duration_ms` | `db:migrate` (every deploy) |
| `app.boot` | info | `process` (web or jobs), `revision`, `rails`, `ruby`, `log_format`, `log_level`, `slow_request_ms`, `sentry` | a web or job process starts |
| `noise_summary` | info | `window_s`, `total`, `items` (`what`, `count`, `total_ms`) | every 5 minutes while routine traffic flows |
| `log` | as logged | `msg` (redacted) | anything else written to `Rails.logger` (Puma's own start-up lines are plain text and stay so) |

Under systemd each line carries a `<n>` priority prefix, so `journalctl -p warning -u rupert-web`
shows only warnings and worse.

## What is never logged

* Parameter **values**, file contents, file names, request or response bodies, cookies, headers, query values (only names).
* Email addresses (a short hash identifies a repeat offender), passwords, tokens, card and bank numbers,
  email bodies, chat text. Job arguments are off (`config.active_job.log_arguments = false`).
* Free text that must be logged (an exception message) goes through `OpsLog.safe_text`: the request-log
  parameter filter (`config/initializers/filter_parameter_logging.rb`, via `FeedbackSanitizer`), emails,
  digit runs of six or more, double-quoted values and object dumps are removed, and the text is cut at 200 characters.
  This is best effort for *messages*; the structured fields are the guarantee, and the tests below prove it for the fields.

`test/integration/ops_log_test.rb` sends passwords, bearer tokens, card numbers, CSV rows, an email body and chat text through
login, feedback, settings import, upload and API paths and fails if any of it appears in the log. Add a new filtered
parameter to `filter_parameter_logging.rb` and it is covered here too.

## Noise control

Routine traffic is written at `debug` (so invisible at the default `info`) and counted; one `noise_summary` event
per five minutes says how much was held back. Quiet means **fast and successful**: `/up*`, `POST /internal/workspaces/claim`
that answered, and signed-out `GET /` or `GET /login`; plus job runs under one second. Any 4xx/5xx, any slow request
and any job failure on those paths logs normally. `RAILS_LOG_LEVEL=debug` shows everything.

Who is polling (checked 2026-10-21):

* `POST /internal/workspaces/claim` every 15 s is the **customer provisioner** on the SER8 host
  (`deploy/ser8/customer_provisioner.py`), asking for new customer workspaces. It was ~5,800 authenticated database reads a
  day for nothing. It now doubles its delay while idle, up to 60 s (`RUPERT_PROVISIONER_MAX_IDLE_SECONDS`; set it to `15` for
  the old rate), and goes back to 15 s as soon as it finds work. A new workspace may therefore wait up to a minute to start.
* `GET /` then `GET /login` about every 31 s is an external uptime monitor or health check, not a person. It reaches Rupert
  through the WireGuard peer and cannot be identified from Rupert's side. Point it at `/up` (a cheap, unauthenticated
  `200`) instead of `/`, which renders the landing page or a login redirect each time.
* Nearly every request (2,562 of 2,587 in six hours) shows `ip: 192.168.3.1`, the WireGuard peer in front of Caddy. The real
  client address is not forwarded, so the IP in these logs, the login throttle and Rack::Attack's per-IP limits all see one
  address. Fix it at the proxy (forward `X-Forwarded-For` from the front host and set Caddy `trusted_proxies` to that peer);
  Rails already trusts private addresses for `X-Forwarded-For`. Not changed here.

## Slow requests and errors

* A request at or above `RUPERT_SLOW_REQUEST_MS` (default 2000) is a `warn` line with `"slow":true` and is kept for the System page.
* Unhandled exceptions: the request line has `error_class`, a redacted message and application frames; the `exception` event
  has 12 frames. Rails' own multi-line exception dump is moved to `debug` so a JSON line is not carrying 4 KB of backtrace.
* Failed jobs: `job` event (`outcome: failed`), plus `job_retry`, `job_retry_exhausted`, `job_discarded`. Solid Queue keeps the
  failed execution for retry; **System → Background jobs → Failed** counts them.
* **Sentry is off in production**: `/etc/rupert.env` on SER8 has no `SENTRY_DSN`, so `config/initializers/sentry.rb` does nothing.
  To turn it on set `SENTRY_DSN` (and optionally `SENTRY_ENVIRONMENT`, `SENTRY_TRACES_SAMPLE_RATE`) and restart `rupert-web` and
  `rupert-jobs`. It sends no request bodies, cookies, headers (except `User-Agent` and `X-Request-Id`) or user data
  (`send_default_pii = false`), tags the release with the deployed revision, and now redacts exception messages through
  `OpsLog.sentry_before_send`. `app.boot` reports `"sentry": true|false`, and the System card says "Sentry on/off".

## System page card

**System → Recent errors and activity** (platform administrators with `system.read`, like the rest of the page) shows the last
24 hours: counts of server errors, slow requests, permission denials, rejected forms, sign-in failures and job failures, and the
ten most recent distinct problems with repeat counts and the first eight characters of the request id. There are no log
lines on the page. The same rows come back from the `recent_errors` MCP tool as `logged_problems`.

The rows live in the `ops_events` table, written by `OpsLog` for every warning and error event (repeats of one problem within
ten minutes are counted on one row), kept `RUPERT_OPS_EVENT_DAYS` (default 14) and capped at 5,000 rows. Set
`RUPERT_OPS_EVENTS=0` to stop writing them.

## Reading the logs

On SER8 (inside the `rupert` container; install once: `install -m755 deploy/ser8/rupert-logs /usr/local/bin/`):

```sh
rupert-logs request 6b75f3fc            # everything one request did (first 8+ characters of the id)
rupert-logs user 5                      # what one user did in the last 24 hours
rupert-logs upload 3                    # the last three uploads, each with its import result and request line
rupert-logs errors --since "2 hours ago"
rupert-logs slow
rupert-logs noise
rupert-logs --json tail | less          # the raw lines
```

With plain journalctl and jq (laptop or any host with jq; the container has none):

```sh
journalctl -u rupert-web -u rupert-jobs -o cat --since today | jq -R 'fromjson? | select(.event=="request" and .status>=500)'
journalctl -u rupert-web -o cat | jq -R 'fromjson? | select(.user_id==5)'
journalctl -u rupert-web -p warning --since "1 hour ago"
```

From the laptop: `ssh sdolbec-ser8 'incus exec rupert -- rupert-logs errors'`.

## Settings

| Variable | Default | Effect |
| --- | --- | --- |
| `RUPERT_LOG_FORMAT` | `json` in production, `rails` elsewhere | `json`, `text` (one readable line per request and event) or `rails` (Rails' default log, no request events) |
| `RAILS_LOG_LEVEL` | `info` | `debug` also shows held-back routine traffic and Rails' exception dump |
| `RUPERT_SLOW_REQUEST_MS` | `2000` | threshold for slow-request warnings |
| `RUPERT_LOG_QUIET_JOB_MS` | `1000` | successful jobs faster than this are counted, not written |
| `RUPERT_LOG_SUMMARY_SECONDS` | `300` | window of the `noise_summary` |
| `RUPERT_OPS_EVENTS` / `RUPERT_OPS_EVENT_DAYS` | on / `14` | the System page store |

Falling back: if the structured logger cannot install itself the app boots with Rails' default logging and prints why on
standard error (a failed boot would roll back the deploy). `RUPERT_LOG_FORMAT=rails` in `/etc/rupert.env` restores the old
log without a code change.

## Retention and rotation

Rails writes no log files in production, so there is nothing to rotate: **journald is the log store.** Install
`deploy/ser8/journald-rupert.conf` inside the container:

```sh
install -Dm644 deploy/ser8/journald-rupert.conf /etc/systemd/journald.conf.d/rupert.conf
systemctl restart systemd-journald && journalctl --vacuum-size=400M && journalctl --disk-usage
```

It makes storage persistent, caps the journal at 400 MB (and keeps 2 GB of the disk free), rotates daily or at 32 MB, deletes
anything older than 30 days and rate-limits a crash loop to 5,000 lines per 30 s per service. Before this the journal had no
cap and held 955 MB. A request is now one line instead of three or four and routine polling is no longer written, so 400 MB should
cover well over the old three days; check `journalctl --disk-usage` and `journalctl --list-boots`/oldest entry after a week and adjust. The System card's "kept for N days" is the problem
store, not the journal.

**`log/test.log`.** Production never writes it. The 51 MB file was created on 2026-10-17 by someone (or a script) running
the test suite (`RAILS_ENV=test`, which logs to `log/test.log`) from `/opt/rupert/web`. At the source: the test environment now
logs to `tmp/log/test.log` (`config/environments/test.rb`), so a test run can never again fill `log/` in a deployed checkout.
The stale file can be deleted: `rm /opt/rupert/web/log/test.log` (not done from here).

## Developing with it

* `OpsLog.event('name', level: :warn, some_id: 5, outcome: 'rejected')` writes an event. Pass ids, kinds, counts and durations;
  pass free text only through `OpsLog.safe_text`. `OpsLog.import(kind:, outcome:, rows: …)` is the shortcut for imports.
  Warnings and errors are stored for the System page automatically (`persist: false` opts out).
* Tests: `include OpsLogHelper` (`test/support/ops_log_helper.rb`) and `capture_ops_log { … }` returns the parsed JSON lines.
  It attaches a **plain** `Logger`: never `broadcast_to` a logger that responds to `tagged` (`ActiveSupport::BroadcastLogger`
  would run every tagged block once per logger, which made requests and jobs run three times). The regression test in
  `ops_log_test.rb` and `feedback_reports_test.rb` guards this.
* The code is in `web/lib/ops_log.rb` and `web/lib/ops_log/`, required explicitly from `config/initializers/ops_log.rb`
  (excluded from autoloading so the formatter and middleware are never reloaded).

## What is verified

See the pull request for the run: the Rails test suite, rubocop, the Python deploy tests, a production-mode boot (JSON lines from
Puma, `app.boot`, request, 404 and CSRF-failure lines), `db:migrate` events from an empty database, and the System card on a
phone and desktop in light and dark. Not verified: a real deploy to SER8, journald behaviour with the drop-in (installed from
this document, not from this change), and Sentry delivery (no DSN exists).
