# Shopify influencer discounts — October 16, 2026

[PR #75](https://github.com/techmore/rupert/pull/75) adds **Marketing → Influencers → collaboration → Create Shopify code**. A local immutable draft records percentage/fixed value, required expiry, minimum subtotal, bounded usage and customer-use rules. A discount manager/reviewer explicitly confirms the displayed store and full terms before the Shopify mutation. Owned results are read back and attached to the influencer's offer; copy actions recheck Shopify and produce a discount-applying referral URL with campaign/influencer/offer tags.

## Release and validation

SER8 release `650b4d715703523666670e89ba64cd688b882185` preserves prior production `c79549b10292fa96d53e1c329353c244dbb1afc2`, including POS checkout, timesheets, source diagnostics, reporting/retention and the influencer CMS. [Hosted CI](https://github.com/techmore/rupert/actions/runs/38850306588) passed on the exact deployed revision: SQLite **1,221 tests / 8,901 assertions**, zero failures/errors/skips; PostgreSQL **1,221 tests / 8,886 assertions**, zero failures/errors and two adapter-specific skips. Local combined SQLite matched the hosted result. RuboCop inspected **645 files** without offenses. Product-site and documentation links passed. The three GraphQL operations passed Shopify AI Toolkit validation against the pinned **2026-07** schema.

A consistent production copy passed migration rollback/reapply, eager loading, compiled assets, integrity and foreign-key checks. All **143 prior-table counts** were preserved, and the new discount table remained empty. Promotion used the shared deployment lock, exact-base/configuration checks, a fresh quiesced database backup and the rehearsed assets. Existing Marketing/credentials/permission overrides were preserved. Postflight confirmed the exact clean release, active web/jobs, the discount schema, database integrity and public HTTPS health HTTP 200; signed-out CMS access redirected to login.

Rollback-only production-mode smoke exercised draft/confirmation/result recovery, code-applying referral copying, encrypted request storage and the live review/collaboration templates. **Real HTTP was forbidden in this process** and a synthetic Shopify API double supplied merchant responses. All synthetic local records rolled back; canonical orders/order lines/variants were unchanged. The browser review screen was also checked with synthetic local preview data. This does not claim a real merchant discount was created or redeemed.

## Shopify access still required

A separate authorized read-only live preflight confirmed campaign domains match the connected store's primary storefront, but the connected app currently lacks **`write_discounts`**. No app permission, merchant code or merchant setting was changed. The repository's scope declaration does not grant a merchant installation access. Granting that access and completing Shopify's app authorization is a separate owner-approved setup step. Until then, Rupert reports the missing permission and blocks discount drafting/creation. No automatic scheduler/retry will create a code.

## Recovery

The private checkpoint is `/var/backups/rupert/pre-shopify-codes-650b4d7`; Incus snapshot `pre-shopify-codes-650b4d7` precedes promotion. Restore prior compatible code/assets through the SER8 host workflow and retain the additive discount table, current data and encryption configuration. Do not restore an older database merely to revert code. Database rollback never revokes a Shopify discount; manage any real live code in Shopify. Never automatically retry an uncertain creation. Check its exact owned result first.

See the [operator guide](shopify-influencer-discounts.md) for supported terms, permissions, current-state checks and recovery of Creating/Uncertain records.
