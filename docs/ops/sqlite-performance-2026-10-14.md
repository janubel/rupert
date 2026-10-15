# SQLite performance experiment — October 14, 2026

Measured on SER8 inside the Rupert Incus instance using a private, consistent copy of the live database. Baseline application code: `6c65ab86da6462f60decb1575b58933ef60c91d6`. SQLite library: **3.53.2**. Customer/order contents, search terms, tenant IDs and credentials stay on SER8; the published [JSON receipt](https://techmore.github.io/rupert/data/sqlite-performance-2026-10-14.json) contains only sanitized timings, query plans and aggregate counts.

## Promoted changes

1. Include the search digest in inventory stock-map cache keys. The prior key used only the page number, so a second search could display zeros from a different product set's cached map. Regression tests reproduced the wrong quantity before the fix. The rendered inventory table uses a new cache namespace so previously cached incorrect HTML is not reused after deployment.
2. Preload each page's variants once and reuse those objects in stock-map calculation and the view, removing the per-product association queries.
3. Add `idx_sync_runs_tenant_started_at` on `SyncRun(tenant_id, startedAt)` and `idx_customers_tenant_created_id` on `customers(tenant_id, created_at, id)`.
4. Order customers by descending creation time and ID so equal timestamps produce stable pagination.

The indexes are expressed as a reversible Rails migration and included in both adapter schema dumps. The other candidate indexes were not promoted: this dataset did not show a useful improvement for those paths.

## Warm SQL timings

Five alternating baseline/candidate rounds on separate database copies, using WAL and synchronous=NORMAL. Each query had five warmups and 100 measured samples per round. Values below are the median of each round's p95, in milliseconds. Baseline and candidate results matched by digest in every round.

| Query | Baseline p95 | Candidate p95 | Query plan change |
| --- | ---: | ---: | --- |
| Latest tenant sync | 0.7350 ms | 0.0080 ms | Full table scan + temporary sort → tenant/time index lookup |
| Customer page (25 rows) | 0.2386 ms | 0.0447 ms | Tenant filter + temporary sort → tenant/time/ID index lookup |

These are small absolute SQL costs. They are not measurements of browser response time, and the ratios must not be presented as whole-application speedups. The initial broader experiment tested eight queries against six individual index candidates, 60 samples each; its raw results are retained in the receipt.

## Inventory assembly

The Rails application read a separate private snapshot with the query cache disabled and an isolated memory cache. Each variant ran seven trials; the first two were discarded. The measurement includes stock-map assembly and the view's variant traversal for 40 products, not HTTP authentication, rendering or network time. Canonicalized stock results matched in every trial.

| Metric | Baseline | Candidate |
| --- | ---: | ---: |
| SELECT statements | 50 | 10 |
| Variant SELECT statements | 41 | 1 |
| Median assembly duration | 15.718 ms | 8.630 ms |

The synthetic regression test likewise exposed unbounded variant queries before the fix and now enforces a bounded query count across a page of products. Separate requests with different searches verify the cached quantities remain correct.

## Write overhead and contention

The five alternating WAL/NORMAL rounds also inserted 100 synthetic rows per table per round, each as its own transaction, on copies only. Median round-p95 insert costs were 0.0704→0.0684 ms for customers and 0.0662→0.0696 ms for sync records. This small test found no material insert penalty; it does not establish the cost of full production imports or sustained load.

A separate synthetic WAL/NORMAL probe used four readers and 300 total transactions, with a deliberate 1 ms lock hold. Both one- and three-writer cases completed all 300 increments without SQLITE_BUSY errors. Total duration was similar (347 vs 342 ms), while maximum write latency was 11.6 vs 228.8 ms. These are single bounded runs, not a statistical capacity study. They support retaining the conservative one-thread job default; they do not establish a production concurrency limit.

## Reproduction and limits

The [research harnesses](https://github.com/techmore/rupert/tree/main/docs/research/sqlite-performance-2026-10-14) were run only in a private scratch directory. Use a quiescent snapshot and a fresh output directory. The baseline snapshot must predate the new indexes. The inventory harness requires Rails booted at the baseline commit and the candidate controller path as its argument; do not treat today's already-upgraded app as the old implementation. No harness should be pointed at the live writable database.

Validation includes both database-adapter suites, regression tests for search-cache correctness, bounded variant queries and tenant-safe stable pagination, and migration rehearsal before production promotion. Production HTTP p50/p95, full sync throughput, larger multi-tenant datasets and off-host recovery are separate remaining checks.
