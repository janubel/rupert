# C-Trax retail and daily reconciliation release — October 15, 2026

[PR #64](https://github.com/techmore/rupert/pull/64) adds the paired cashier/customer cart and private-tip preview, website image associations and daily sales/register reconciliation. The production rollout preserved the other reporting, marketing and backup changes. Internal recovery details are stored only in the owner's private backup.

Real production stock and daily sales/register reads succeeded using the existing encrypted account. Both imported business days matched every independent native report check: order count, total, tax, discount, tips and five base-tender totals. No C-Trax payment, stock, register-close or merchant configuration was changed. Normalized financial snapshots were verified encrypted, and the daily views rendered with real records. The actual scheduled worker successfully refreshed today/yesterday; recurring sales reads were enabled only after these imports succeeded.

Browser verification in isolated development covered both demo panes, private unconfirmed selection, confirmed percentage and explicit no-tip choices, changed-cart invalidation and cart clearing. This does not claim payment-terminal execution or a new authenticated production cashier browser session. Only unambiguous website image associations render; the local picker covers missing associations without changing source data.

Validation: **1,027 local SQLite tests / 7,472 assertions**, zero failures/errors/skips. Configured Ruby lint, JavaScript syntax, Tailwind, generated site and documentation checks passed. A cloned production database passed migration, loader and asset rehearsal while preserving prior table counts; live migration integrity and foreign-key checks also passed. Production web, workers and backup timer were active with successful public health/login responses after activation.

GitHub checks both adapters. PostgreSQL CI identified a missing daily-table definition in the manually maintained fresh-install schema dump; that definition was corrected. The actual migration and production SQLite were unaffected. The final GitHub check result should be read from the PR, not inferred from the local SQLite result.

A consistent post-import runtime backup was encrypted off-machine with the owner's recovery key; decrypt and all member checksums passed. Detailed recovery references, original records and runtime keys belong in the owner-verified private backup destination, outside this public repository.

See [operator workflow and limits](../ctrax-retail.md). Final tax, payments, collected tips and receipts still execute in C-Trax; the paired screens are a cart/tip preview.
