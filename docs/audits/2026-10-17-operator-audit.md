# Operator and audit-trail review — October 17, 2026

Follow-on to the [finance audit](2026-10-16-finance-audit.md). Live checks were read-only aggregates against the SER8 database; no credentials or customer data were read or copied.

## Findings

| # | Finding | Evidence | Change |
| --- | --- | --- | --- |
| 1 | The audit trail missed the most sensitive actions. Database restore, database backup download, secret (.env) export and import, Google sign-in credential and allowed-domain changes, Drive backup and disconnect, API token issue and revoke, location add, edit and remove, reconciliation reviews, withdrawals, evidence uploads, daily archives, close packages, cash forecasts and follow-ups wrote nothing to the Activity log. | 420 live entries since 2026-10-15, none from these actions. | Each now writes an Activity entry with actor, subject and non-secret details (key names, ids, scopes, checksums prefix; never values). Wrong-password secret export is logged as denied. |
| 2 | The nightly retention job deleted Activity and Access log entries after 90 days, shorter than any financial review period. Live access-log history already reaches back 64 days. | `DataRetention::POLICIES` | Activity is now kept 7 years, sign-in attempts 2 years. Mirrors keep their windows. |
| 3 | Entries without a subject were stored with subject type `NilClass`. | `ActivityLogger` | Fixed (nil subject type). |
| 4 | The Activity page showed only the newest 200 entries with no search, dates, export or paging. | `ActivityController` (9 lines) | Filters (Money / Settings and access groups, text, dates), paging, formula-safe CSV (up to 10,000 rows), `Cache-Control: private, no-store`. |

Not changed, for the owner: role and permission matrices live in code (`role_permissions` and `user_permissions` tables are empty), so there is no per-user override in use; API tokens: none issued; platform signup approvals keep their own event trail (`WorkspaceSignupEvent`).

## Verification
131 related tests pass on SQLite (new `audit_trail_test.rb` plus access, settings, token, location, reconciliation, close, forecast and retention suites). RuboCop clean with `-c ./rubocop.yml`.
