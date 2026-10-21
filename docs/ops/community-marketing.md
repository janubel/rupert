# Community thread and reply review

Phase one provides a tenant-scoped Marketing workspace at `/marketing`. Workspace administrators can enable or disable it there. It starts disabled for existing workspaces. Administrators receive `marketing.read`, `marketing.write`, and `marketing.review` by default; explicit role/person overrides remain in effect. Delegate those permissions through the Permissions screen. Enabling requires a workspace administrator with settings-write access.

## Set up a group campaign

1. Create a campaign with a name, product topics, and public HTTPS storefront URL.
2. Add a group with its URL, comma/newline-separated include/exclude terms, promotion rules, and a source URL for those rules. A reviewer with write/review access confirms the rules after reading them. Confirmation lasts 30 days; editing the rules/source clears it.
3. Record an **existing** merchant discount code for that group. Include all offer terms: value/type, products, minimum spend, usage/per-customer limits, and stacking. Supply start/end times, a destination on the campaign storefront host, and a merchant settings/document URL as verification evidence. Codes are normalized to uppercase and unique per workspace/merchant host.
4. A reviewer checks the actual code and all terms against merchant evidence, then confirms it in Rupert. This dated operator attestation lasts 24 hours. Rupert does not call the merchant to verify or activate the code in phase one. Editing its terms clears verification. Expiry here does not deactivate a merchant-side code.

Dates are entered and displayed in Rupert's configured Eastern timezone; storage is UTC. Confirmation buttons update their current timestamps and invalidate any reply snapshot that relied on the old evidence. Confirm rules, offer and context before submitting a reply.

## Find and triage discussions

Open **Find threads with topic search** beside the group. This opens a Bing site/topic query in a new tab; results are not crawled or imported. Save a relevant discussion URL, title, short excerpt, group, and triage note. Rupert fetches no supplied URLs. Keyword matches/exclusions are shown as review hints. Inspect the original discussion and group rules yourself.

Select Relevant, Dismissed, or Snoozed. Dismiss/snooze require a note; snooze also requires a future date. The default queue hides snoozed threads until due; the status filter can show them earlier. Confirm current context when you have checked the original. Context confirmation lasts 7 days and clears when the URL, excerpt, title, group or availability changes. Locked/deleted threads cannot proceed. Duplicate URLs open the existing record and preserve its reply history. Fragments/tracking parameters are stripped; forum identity parameters are retained. Reddit queries are discarded because thread identity is in its path.

## Draft, review and publish manually

Save one reply per thread with useful discussion-specific text, clear brand affiliation and an offer belonging to that group. Rupert composes the submitted copy from that text plus affiliation, code, offer terms/expiry and a UTM-tagged storefront link. The UTM link identifies the campaign/group/offer; it does not measure clicks or establish conversions in this release.

Submit the exact revision for review. A reviewer can approve, reject or request changes. Review notes are required for rejection/changes. Approval checks that the thread is open/relevant, rules/context are fresh, the offer is active and freshly confirmed, and the current context matches the submitted snapshot. Writing and reviewing have separate permissions; an administrator can perform both during a small pilot.

Use **Open approved copy** to obtain a readonly copy after the same eligibility checks. Publish it yourself. Record the reply URL and confirm that its wording matches the approved copy. Changed wording must be saved/submitted for a new review. An approval does not post anything. A publication record is an operator attestation, not provider-verified evidence. If removed, record the reason; the existing thread/reply stays visible so operators do not repeatedly contact it.

Editing drafts clears approval. Changes to campaigns, group context, offers, or thread context prevent copying/publishing an earlier approved snapshot. A stale edit is rejected instead of overwriting a newer revision. Revision/review events retain actor, text, offer, decision and publication evidence; the reply page shows the latest 50 events. Group/campaign selectors show up to 200 entries, offer lists the latest 30, pending review the oldest 30, and threads paginate in groups of 30. These limits are shown in the UI.

## Release and limits

The migration adds six marketing tables; existing commerce tables are unchanged. Run the SQLite test suite. Before live migration, retain a consistent database backup and rehearse migration/rollback/reapply on a copy. Deploy atop the current SER8 release so ongoing reporting changes are preserved. Enable only the intended pilot workspace. Disable Marketing to stop access without discarding history. Compatible code rollback can leave the new tables in place; do not roll back the migration after collecting marketing records without preserving them.

Automated discovery adapters, provider posting, AI-generated replies, influencer CMS/gifting, automatic discount creation/revocation, public referral redirects, click analytics and order attribution are later phases. Keep merchant promotion rules and platform access requirements with each source when those adapters are implemented. No Shopify/Square mutation is part of this workflow.
