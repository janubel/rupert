# Morning product evidence review — October 21, 2026

Reviewed `main` at `59cc99f3` in an isolated worktree. This continues maintenance
task 04; the saved automation remains paused. The Rails modular monolith is the
current source. Rust core is retired; mobile distribution and merchant acceptance
remain separate evidence levels. This review makes no deployment claim.

## Finding and one coherent improvement

PRs #260, #261, #262 and #264 are already merged. Their source includes
`DailyCloseSummary`, `SwipesimpleDailyReport`, the SwipeSimple report/item readers,
and C-Trax daily items. F56 and the public daily-summary comparison omitted the
new source-separated SwipeSimple cash/card/refund/tip view; F66 omitted native-ID
item tie-outs. The SwipeSimple comparison caveat still described CSV-only reads.

Updated the catalog and comparison source, then regenerated the public JSON,
CSV and HTML. Both F56 and F66 remain **Partial**. A transaction export does not
supply SwipeSimple sales tax. Missing C-Trax drawer evidence, unsupported item
allocations/refunds, fees and payment-to-bank settlement remain explicit gaps.
Independent source totals are not added together. Website exports do not imply a
supported partner API or merchant account entitlement. Existing vendor review
dates remain unchanged; this is a review of Rupert source scope.

## Ranked next opportunities

| Rank | Opportunity | Value, fit and adoption gate |
| --- | --- | --- |
| 1 | Verify one physical count sample using existing C-Trax/Shopify worksheets | Highest daily stock value; existing Rails code, no new dependency or account. Exact source/location/identity, shelf observation and owner review are required. No automatic stock equalization. |
| 2 | Pilot the existing source-separated daily close and item tie-outs | Direct operator/bookkeeping value; existing Rails snapshots and reviews. Require matched period/currency/source and a bookkeeper's real trading-day review, including later refunds and deposits. No live payment or source close is part of this audit. |
| 3 | Use the merged role-aware first-week learning journey | Low integration and resource cost; existing components and permission gates. Narrow-screen fixture review is recorded separately; staff/device acceptance is still needed. |

The strongest opportunity is physical inventory verification. A new inventory,
ERP or payment-provider dependency would duplicate existing coverage before the
physical and merchant gates pass. No new tool or provider is proposed, so no new
licensing, credentials, hosted processing, security or maintenance surface is
introduced. Existing maintained project code is the appropriate implementation
boundary for these opportunities. Do not infer merchant processor/terminal facts.

## Checks and next iteration

- Product site generator and consistency check: 68 features, 18 competitors,
  38 comparison rows.
- Local documentation links verified across 21 generated pages.
- Focused daily close/report/item regression results are recorded in the PR.
- No platform request, account creation, outreach, production mutation, dependency
  addition or payment operation occurred.

Next iteration: an operator verifies a small agreed shelf sample privately, then
reviews one actual trading day across its existing source and bank evidence.
Fixture success does not substitute for those observations.
