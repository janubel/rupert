# Page performance

Every page should answer in tens of milliseconds and every interaction should feel instant.
Three tools keep it that way.

## 1. Page budget (runs in CI)

`web/test/integration/page_budget_test.rb` loads the most-used pages as a platform
administrator and fails when one runs more SQL queries than its budget. A page that starts
asking the database once per row (N+1), or rebuilds shared data per call, trips it long before
anyone feels it. Raise a budget only with a reason in the commit message; add new major pages.
`BUDGET_REPORT=1` prints the measured counts.

## 2. Whole-suite audit (on demand)

```
PERF_AUDIT=1 bin/rails test    # on a SER8 test container, never the laptop
bin/perf-audit-report 40
```

While the normal suite runs, `test/support/performance_audit.rb` records every controller action
it exercises: query count, duration, the most repeated statement, and Rails' N+1 warnings (strict
loading in `:n_plus_one_only` mode, logged not raised). The report ranks actions by queries and
lists repeated statements (≥ 5 in one request) and N+1 warnings.

## 3. Patterns

- **Once per request.** Shared lookups go through a per-request cache: navigation entries
  (`nav_entries`), feature flags (`FeatureFlag.enabled?`), platform settings
  (`EnvStore.platform_settings`), tenant settings (`EnvStore.all_scoped`). Writers clear them.
- **Batch writes.** Saving many money records at once wraps the loop in `PeriodLock.batch` so
  locks are read once for the batch, not once per record.
- **Preload what a list shows** (`includes`), and group counts (`group(:status).count`) instead of
  one count per status.
- **Expensive summaries are cached** briefly (`SystemPresenter` 60 s, `HostVitals` 30 s).
- **Browser:** fingerprinted assets are served with a one-year immutable cache header
  (`ImmutableAssetCache`); Turbo prefetches links on hover; a form that returns to the same page
  morphs it in place and keeps the scroll position; the display font loads without blocking paint.
- **Server health** for the platform administrator is in the status bar (CPU, memory, disk,
  database size, last backup), from `HostVitals`.
