# Uploads inbox

**System → Uploads** (`/uploads`) is the one front door for files sent to Rupert: bank statements, QuickBooks exports, SwipeSimple, NAB / IRIS, Authorize.net, timesheets and anything else. A file is received, kept, recognized and previewed first. Only a person's explicit approval, after a dry run, ever changes a business record. This follows the rules in [historical records](historical-records.md) and [bank statements](bank-statements.md): originals are kept byte for byte, nothing is guessed, and a repeat is never imported twice.

Added 2026-10-21. Use real exports only in the app; keep them out of this public repository (the tests use invented data).

## What a person sees

- **Upload box.** Drag files onto it or choose them (CSV, Excel `.xlsx`, JSON, PDF, text). Up to 10 files per send, 10 MiB each, 25 MiB per send. Works from a phone.
- **Every upload**, newest first, filterable by status, with who sent it, when, size, format, what Rupert thinks it is (with a percentage), the line count and the reason for any refusal or hold.
- **A detail page** per file: facts and SHA-256, what Rupert thinks it is and why, the other possibilities, a choice of importer, a **preview of the first rows as plain text**, the dry-run result and the **Approve and import** button, plus Discard / Reopen and a download of the original.
- **Statuses.** *Received* (kept, not yet looked at), *Recognized* (matched to an importer; nothing has changed), *Needs review* (not sure, or no importer yet; a person decides), *Imported* (approved and imported), *Rejected* (refused or discarded, with the reason), *Duplicate* (identical bytes to a file already kept; not stored again).
- **Re-run recognition.** After a new importer ships, the list shows how many held files were looked at before it existed. One button looks at every open file again. A file whose type a person already confirmed keeps that choice.

## The path a file takes

1. **Intake** (`Uploads::Intake`) is the only entry point for the web page, the API and the drop folder. It cleans the file name (it is only ever a label), checks the extension against the five allowed types, reads at most the size cap, checks the bytes really are that type (text must decode as UTF-8, UTF-16 with a byte-order mark, or Windows-1252, never binary; a PDF must start `%PDF-`; JSON must parse; an `.xlsx` must be a sound zip), then stores the original once, encrypted, with its SHA-256. An identical file already kept becomes a *Duplicate* row pointing at the first one. A refused file keeps only a metadata row (name, size, hash if read, reason), never its bytes.
2. **Recognition** (`Uploads::Recognizer`) asks every importer to sniff the file and picks one only when it is clearly ahead: confidence of at least 75% and 15 points over the runner-up. Anything else waits as *Needs review* with the reason. A file that is named but has no importer (Square, Rupert's own timesheet export, an Excel copy of a QuickBooks report) also waits, saying so.
3. **Dry run.** The operator fills in anything the importer cannot know (for example the account name for a bank statement; never an account number) and runs a dry run. The dry run executes inside a database transaction that is **always rolled back**, whatever the importer does, so it cannot change a record. It reports exactly what an import would do.
4. **Approval.** *Approve and import* only appears after a successful dry run of the same file, importer and settings (a digest binds them; changing any setting invalidates it). The person must hold `uploads.write` **and** the permission of the destination (for example `finance.write` for bank statements, `sync.write` for SwipeSimple and Authorize.net, `inventory.write` for item lists, `settings.write` for IRIS). The import runs in one transaction together with the status change.

## Importers

| Importer | Recognizes | Needs from the person | Approving does |
| --- | --- | --- | --- |
| Bank statement | A date, a description and an amount (or debit and credit) column | Account name, withdrawal sign | Reads statement lines for review on Bank transactions; creates no expense |
| SwipeSimple sales line items | The documented line-item columns | none | Creates completed sales orders (`SwipesimpleImporter`) |
| SwipeSimple item list | Item name plus SKU, price, stock or category | Merchant account | Replaces that account's item snapshot |
| SwipeSimple web report | Every native Transactions or Invoices column | Merchant, time zone, export time | Saves reconciliation evidence rows, no sales |
| NAB / IRIS Daily Deposits | `Daily Deposits` and `Records exported` | Merchant number, month | Saves a report snapshot, no sales |
| Authorize.net portal | The native Expanded Fields columns | Gateway ID, settled or unsettled, export time | Saves a portal snapshot |
| QuickBooks CSV | Chart of accounts, journal / general ledger / transaction detail, vendors, customers, trial balance (title and columns) | Trial balance: the as-of date | **Stages** the file on the History page. Its own approve, post and reverse steps stay there |

The QuickBooks adapter is wired to `QuickbooksCsv` and `QuickbooksImport` from the History import and only reports "importer not installed yet" until that feature is present; **Re-run recognition** then picks held files up.

Square exports, Rupert's own timesheet export and C-Trax-named files are recognized but have no importer: they stay as *Needs review* with that reason. The Square signature (Gross Sales and Net Sales, or Token, Item Name and Variation Name) comes from Square's published export layouts and has not been checked against a real file.

### Adding an importer

Subclass `Uploads::Importers::Base` in `app/services/uploads/importers/`, declare it with `importer 'key', label:, source:, permission:, formats:, errors:`, implement `detect(document)` (a `Uploads::Detection` with type, label, confidence 0 to 1 and a plain-language reason, or nil), `dry_run(document, params, upload)` and `import!(document, params, upload, actor:)` (each returns an `Uploads::Outcome` through the `outcome` helper), optionally `params_spec`, `suggested_params` and `preview`, then add its class name to `Uploads::Registry::IMPORTERS`. `document` gives decoded `text`, sampled `rows`, `header_keys` (lower-cased, letters and digits only) and `bytes`. Importers should raise one of their declared `errors` with a message a person can act on. Do not log from an importer; the workflow records the outcome.

## Safety rules

- **Never executed or followed.** Files are data. Nothing inside one is run, opened as a link, evaluated or fetched. Excel workbooks are read only for cached cell values (macros, formulas, external links and embedded objects are ignored); PDFs are not opened at all.
- **Formula injection.** The preview escapes every cell and marks values starting with `=`, `+`, `-`, `@`, tab or carriage return (ordinary negative numbers are not marked). Anything leaving Rupert as CSV or JSON goes through `Uploads::Cell.neutralize`. The original downloads only as `application/octet-stream` attachment with `nosniff` and a sandbox policy; opening a downloaded CSV in a spreadsheet is the reader's risk, and the page says so.
- **Zip bombs and size.** The `.xlsx` container is judged from its directory before inflating anything: at most 500 parts, 100 MiB expanded, 100:1 compression, no encryption, no zip64, no unsafe part names; single parts inflate under a hard output cap. Files over 10 MiB are refused without reading them whole.
- **Encoding.** UTF-8 (with or without a byte-order mark), UTF-16 with a mark and Windows-1252 are accepted for reading and labelled; the stored original is never rewritten. Importers are given the decoded text.
- **File names** are normalized, stripped of path, control and bidirectional-override characters and leading dots, and used only as labels.
- **Permissions and tenancy.** Viewing needs `uploads.read`, everything else `uploads.write` (administrators by default; grant either per role or person in Permissions). Every query is scoped to the workspace; another workspace's upload is a 404.
- **Limits.** 10 files / 25 MiB per send, 500 uploads per workspace per 24 hours and 2 GiB of retained originals (capacity is rechecked under the SQLite writer lock before each row, including rejections; a new original must fit the remaining byte allowance and duplicates add no retained bytes), 30 sends per minute per browser address and per API token (Rack::Attack).
- **Logs.** Log lines and the Activity trail carry the event, upload id, SHA-256, byte size, format, detected type, status and origin. Never file contents, cell values, import parameters or file names in the application log. (`[uploads] event=received id=7 sha256=... byte_size=89 file_format=csv detected_type=bank_statement status=recognized origin=api outcome=recognized`.) Failures go to `Rails.error` with the upload id only.
- **Originals are append-only.** The retained bytes, hash and size cannot be changed through the model, and the checksum is verified on every read. There is no delete path; *Discard* only removes a file from the open list and can be reopened.

## Insights: using the inbox's own numbers to improve it

**System → Uploads → Insights** (`/uploads/insights`, needs `uploads.read`) charts how the inbox is working over the last 30, 90 or 365 days (days up to 90, then weeks). It is for deciding what to build or tighten next, so each view maps to a decision:

| View | What it shows | What to do with it |
| --- | --- | --- |
| Headline numbers | Files received, files waiting for a person (and the oldest), share held for review, median time from received to imported | A growing waiting count or oldest age means files are arriving that nobody is deciding; a high held share means recognition is missing too much |
| Uploads by outcome | Stacked columns per day (week for 365 days): imported, recognized, needs review, rejected, duplicate | Spot a rise in amber (needs review) after a new kind of file starts arriving |
| How far files get | Kept, matched an importer without help, passed a dry run, imported | The biggest drop is the step to improve: sniffing (kept to matched), importer parsing (matched to dry run) or the approval habit (dry run to imported) |
| Why files wait or are refused | Counts by `reason_code`: not recognized, recognized with no importer, importer not installed, not sure enough, two close matches, dry run failed, import failed, unsupported type, not text, too large, empty, discarded, sent again | **Recognized, no importer** is the ranked list of importers to build; **not recognized** are candidates for new sniffers; **dry run failed** points at parsers and messages; **sent again** shows people not seeing that their file arrived |
| What Rupert thinks files are | Per detected type: files, average confidence, share held, share where a person chose the type by hand, imported | A high "chosen by hand" share means that sniffer is too loose or too shy; tune its signature |
| Importer health | Dry runs passed and failed, imports and import failures per importer (from the activity trail, so only since importer keys were recorded) | A low pass rate means people send a layout the importer rejects: read its messages, widen the parser or sharpen the error |
| Where files come from | Browser, API, drop folder | Zero from the API or drop folder means the no-UI route is unused or unknown |

Each chart has a table behind it (the outcome chart under *View as a table*) and every column carries a text description, so nothing depends on colour. Chart colours are validated for contrast and colour-blind separation in light and dark. The page reads counts, times and `reason_code` values only: no file contents, cell values, parameters or file names, the same rule as the logs. `reason_code` is stored beside the human reason on every upload (`Uploads::Insights::REASONS` lists the codes); rows from before it existed show as "Before reasons were recorded".

When something here should change the product, record the decision in the PR that makes the change and look at the same view a few weeks later.

## Sending a file without the web page

### API (recommended for scripts and other machines)

1. In **System → API access** create a token for a person who holds `uploads.write`, with the scope **`uploads:write`** (and `uploads:read` to ask what happened). The token is shown once.
2. From any machine that can reach Rupert (for example another computer on the tailnet):

```bash
curl -H "Authorization: Bearer $RUPERT_API_TOKEN" -F file=@statement.csv https://YOUR-RUPERT-HOST/api/v1/uploads
```

Several files: repeat `-F files[]=@a.csv -F files[]=@b.csv` (up to 10, 25 MiB together). The reply is JSON with, for each file, the upload `id`, `status`, `status_text` (the reason), `sha256`, `byte_size`, the detected type and confidence, and `review_url` (`/uploads/ID`). Status codes: `201` kept, `200` already had it (duplicate), `422` every file refused (reason in `status_text`), `400` no file or too many, `401` bad token, `403` missing scope or permission, `413` request too large, `429` rate or daily limit. To check later:

```bash
curl -H "Authorization: Bearer $RUPERT_API_TOKEN" "https://YOUR-RUPERT-HOST/api/v1/uploads?status=needs_review"
curl -H "Authorization: Bearer $RUPERT_API_TOKEN" https://YOUR-RUPERT-HOST/api/v1/uploads/7
```

A token can send files and read their status. **It can never approve an import**; that is only done by a signed-in person in the app. Revoking the token or removing its owner's permission stops it immediately. If Rupert sits behind a proxy, allow request bodies of at least 26 MiB on `/api/v1/uploads` and `/uploads`.

### Google Drive (alongside upload)

**System → Uploads → Or copy from Google Drive** (`/uploads/drive`) is a second way in. A workspace administrator (`settings.write`) connects a Google account once; a person with `uploads.write` then picks files from one folder and copies them into the inbox. Each file takes the same path as a browser upload (kept unchanged and encrypted, recognized, dry run, approval), with origin *Google Drive*.

- **Read-only, one folder.** Consent asks for `drive.readonly`. Google has no narrower scope for reading files you made elsewhere (`drive.file` only covers files an app created or the person opened with Google's picker), so Rupert enforces the limit itself: it lists and reads only the folder chosen on that page, never writes, shares, moves or deletes, and checks every file again with Google before accepting it (still in the folder, not in the trash, supported type, under 10 MiB, checksum matches). Revoke access any time at myaccount.google.com/permissions or with **Disconnect**, which removes the stored token and folder; files already copied stay.
- **Its own token.** Separate from the whole-instance backup token and from [Drive document retention](drive-document-retention.md), stored encrypted per workspace, bound to the person, workspace and a ten-minute state at consent.
- **Google documents are not converted.** Docs and Sheets are listed but cannot be copied; download them as CSV or Excel into the folder first.
- **Limits.** Up to 10 files per copy, 200 files listed, the usual 10 MiB per file and daily inbox limits.
- **Setup.** Uses the platform's existing Drive OAuth client (`GOOGLE_DRIVE_CLIENT_ID` / `GOOGLE_DRIVE_CLIENT_SECRET`) and its registered `/auth/google/callback`. `drive.readonly` is a restricted Google scope: while the OAuth app is in Testing, only listed test users can consent and tokens expire after seven days (see the retention note). Production use needs Google's verification for restricted scopes. **Not yet verified against real Google**: the tests use a stand-in Drive service, and consent was last blocked by the Testing state (see [Google backup verification](google-backup-verification.md)).

### Drop folder (off by default)

For people who can only copy files onto the server (scp, rsync, a mounted share). Enable it deliberately:

1. Create the root as a real directory (not a symlink) owned by the account that runs Rupert and not writable by anyone else, for example `install -d -m 0700 -o rupert /var/lib/rupert/drop`, and one folder per workspace named after its subdomain with an `incoming` folder inside: `…/drop/herbalhealers/incoming`.
2. Set `UPLOADS_DROP_ENABLED=1` and `UPLOADS_DROP_DIR=/var/lib/rupert/drop` in the environment. The recurring job `UploadsDropScanJob` (every minute) does nothing unless both are set.
3. Copy files into `incoming/`. Each file older than 10 seconds goes through the same intake as a browser upload (origin *Drop folder*), then is moved to `processed/<id>-<name>` (kept, or duplicate) or `quarantine/<hash>-<name>.quarantined` (refused). Quarantined files are never read again.

The scanner reads only plain files: symbolic links, hard-linked files, folders, devices and sockets, dot-files and `.part` / `.tmp` files are skipped; files are opened without following links and re-checked after opening; the root and folders must not be world-writable; a folder whose name is not an active workspace is ignored; at most 50 files per run. Tailscale (or any network path) is only how a file reaches the host; Rupert accepts nothing from the network except through the authenticated API.

## Asking where a file went

- **Ask Rupert** answers "where do I upload a file?" with a link to this page (for people who may open it) and, for people with `uploads.read`, "did my file arrive and what happened to it?" through the read-only `list_uploads` report, which looks a file up by name, SHA-256 prefix or id and returns its status, reason and who sent it, never its contents.
- **MCP / AI assistants:** the same `list_uploads` tool with scope `uploads:read`; see [mcp.md](../mcp.md). Assistants cannot upload or approve.

## Verification status

Verified in tests with invented data (`test/services/uploads`, `test/integration/uploads_test.rb`, `test/integration/uploads_api_test.rb`) and in the development server at desktop and phone width, light and dark, including drag-and-drop, a dry run, the API with `curl` and a hostile CSV. Not verified: any real export from QuickBooks, Square, SwipeSimple, IRIS or Authorize.net other than through the existing importers' own contracts; the QuickBooks adapter against the real `QuickbooksCsv` / `QuickbooksImport` (tested against stand-ins until that feature lands); the drop folder on SER8; behaviour behind the production proxy's body-size limit; Excel files produced by real Excel (tests build minimal workbooks).
