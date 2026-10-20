# Security scanning

The **Security** workflow (`.github/workflows/security.yml`) runs on every pull request, on pushes to `main`, and weekly:

- `bundler-audit` fails on any known-vulnerable gem in `web/Gemfile.lock`.
- Brakeman fails on any warning that is **not** in `web/config/brakeman-baseline.json`.

## Baseline triage (2026-10-19, Brakeman 8.1.0, 20 warnings)

Each baseline warning was read in context. None is an open vulnerability.

| Warning | Sites | Why it is accepted |
| --- | --- | --- |
| SQL injection | `search_sql.rb` (FTS5 trigger DDL), `inventory_exceptions.rb` (joins) | Identifiers go through `quote_table_name` / `quote_column_name`; values through `connection.quote`; the tenant id is `connection.quote`d in `quoted_tenant`. No request parameter is interpolated. |
| Dangerous send | projects, tasks, goals, employees `transition` | The event is checked against a literal allow-list (`%w[start hold complete archive]` etc.) before `public_send` / `send`. |
| Mass assignment | `users_controller.rb` (`:role`) | `guard_role_assignment` limits assignable roles; only a super admin can assign `admin` or `super_admin`. |
| Mass assignment | `expenses_controller.rb` (`:account_id`, `:vendor_id`) | Fields are an explicit permit-list; ids are tenant-scoped on lookup. |
| Mass assignment | `bank_statements_controller.rb#decide` (`permit!`) | The hash is only `line id => choice`; ids are re-queried through `for_document(...).pending`, and `apply` validates every choice (category allow-list, withdrawals only). |
| Command injection | `backup_service.rb` (`pg_dump`) | Array form of `system` (no shell); arguments come from the database config, not from a request. |

## Changing the baseline

Fix new warnings where possible. If one is a reviewed false positive, regenerate the baseline (`brakeman --path web --confidence-level 2 -f json -o web/config/brakeman-baseline.json`), add a row above explaining why, and have a second person review the diff.
