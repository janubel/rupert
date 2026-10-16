# Influencer CMS — October 16, 2026

The influencer CMS is available under **Marketing → Influencers** at `/marketing/influencers`. [PR #71](https://github.com/techmore/rupert/pull/71) continues the community-marketing rollout tracked in #54.

## Deployed scope

- Prospect directory, relationship owner/stage, next follow-up and encrypted contact/conversation records.
- Campaign collaborations, deliverables and ordinary storefront UTM referral links.
- Product-gift proposals using exact mirrored variants, estimated budgets, reviewer approval, dated recipient confirmation and manual shipping/delivery/return evidence.
- Existing merchant-created temporary code records with required active dates, full terms and fresh merchant-evidence checks before copying.
- Encrypted, versioned collaboration briefs/documents with separate restricted visibility and review history.

Contact/recipient fields use the separate `marketing.contacts` permission. Administrator defaults include it; explicit permission overrides remain authoritative. No outreach, merchant discount activation, inventory adjustment, platform order, financial posting or automatic shipment is performed by the CMS. Referral links do not claim click/conversion attribution.

## Validation and activation

SER8 release `8c3118f0899b0641a2f8e09e02c2c82badb25bd0` preserves prior production release `9f1b4690a41fc1eb3a72e0164a485fea2e84002c`, including timesheets, source diagnostics, reconciliation/retention, Drive-originals support and automatic native NAB imports. The combined local SQLite suite passed **1,173 tests / 8,512 assertions**, with no failures/errors/skips. RuboCop inspected **619 files**, with no offenses. Product-site and documentation-link checks passed. [Hosted PostgreSQL and SQLite CI](https://github.com/techmore/rupert/actions/runs/38848632805) passed on the exact deployed revision: SQLite **1,173 tests / 8,512 assertions**, zero failures/errors/skips; PostgreSQL **1,173 tests / 8,497 assertions**, zero failures/errors and two adapter-specific skips.

A fresh consistent production copy passed migration rollback/reapply, eager loading, asset compilation, database integrity and foreign-key checks. All **131 pre-existing business/system table counts** were preserved; value comparisons also preserved every existing marketing row and reply-review snapshot. The migration adds eight empty CMS tables and an exclusive group-or-collaboration recipient constraint to shared offers. Rollback-only production-mode smoke covered directory/profile/forms, product-gift delivery, code/referral copying, document revision/escaping and encrypted storage, without retaining synthetic records or changing canonical orders/variants.

The private recovery checkpoint is `/var/backups/rupert/pre-influencer-8c3118f`; Incus snapshot `pre-influencer-32621d5` precedes activation. Promotion uses the shared `/var/lock/rupert-deploy.lock`, validates the exact current revision and unchanged runtime configuration, takes a fresh quiesced database backup, migrates and installs rehearsed assets. The existing Marketing flag and credential/permission settings remain intact. Live verification confirmed the exact clean revision, active web/jobs, database integrity/foreign keys, the CMS migration and public HTTPS health HTTP 200. Signed-out CMS access redirected to login (302). A fresh rollback-only production-mode workflow smoke passed without retaining synthetic records or changing canonical orders/variants.

## Recovery

Restore the saved code/assets and restart the application services using the SER8 host workflow. Keep the additive CMS schema and new records for a compatible code rollback. Do not revert the migration after real influencer records/offers exist, and do not restore the older database merely to revert code: that would discard later business writes. Preserve the runtime encryption configuration and the private checkpoint. Private contacts, addresses, codes, conversation text and merchant evidence do not belong in public Git.

See the [operator guide](influencer-cms.md) for the workflow and limits.
