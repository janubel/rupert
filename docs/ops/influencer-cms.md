# Influencer CMS

Open **Marketing → Influencers** or `/marketing/influencers`. The CMS uses the workspace's existing Marketing feature flag. Workspace administrators receive read/write/review and the separate `marketing.contacts` permission by default; explicit role/person overrides remain authoritative. Delegate contacts access only to staff who need recipient addresses, contact notes, conversations or restricted documents.

## Prospects and collaborations

Add a prospect's name, primary platform/handle/profile URL, audience topics, relationship owner, stage and next follow-up date. Profile URLs are normalized for duplicate detection. The directory searches business metadata and filters by stage or follow-ups due; it does not search encrypted contact fields. Contact email, shipping details and private notes are encrypted and omitted from pages/forms without contacts access. Use ordinary Notes for nonprivate audience fit and business context.

Stages are Prospect, Shortlisted, Contacted, Interested, Active, Completed, Declined and Do not contact. These record your relationship assessment; no outreach is sent by changing a stage. Conversation logs hold actual email/DM/call/meeting notes and dates, are encrypted, and require write plus contacts access. Follow-up dates are a queue filter, not scheduled notifications.

Create a collaboration for each campaign/creator pairing. It has a title, campaign, deliverables, due date, storefront destination and Draft/Active/Completed/Cancelled status. Create the underlying campaign in Community Marketing first. A saved collaboration's campaign cannot be reassigned; create a separate collaboration instead. One influencer can have repeated collaborations, separate gifts and offers.

## Product gifting

1. Propose a gift and record currency, optional estimated shipping cost and a business note. Contacts-authorized operators can copy/edit the prospect's recipient details into the gift; it retains its own encrypted address snapshot.
2. Add product variants from the workspace's mirrored Shopify catalog. Search by variant SKU/title, then select the exact variant, quantity and optional estimated unit cost. The gift retains variant ID, product name and SKU snapshots. Unknown costs remain unknown. Costs use minor currency units; no currency conversion or profit calculation is performed.
3. A reviewer approves the products and budget. Approval needs an Active collaboration, a contactable influencer and at least one valid product. Approved product/cost fields cannot be edited. Cancel and propose a new gift when the budget/products need revision.
4. Record that the recipient confirmed the shipping details. This dated operator attestation lasts 90 days and clears when the address changes. Contacts access is required. Mark the approved gift Ready to ship after confirmation.
5. Complete shipment through the current fulfillment process. Record carrier, tracking number and optional tracking-evidence URL in Rupert; then explicitly attest to the shipment and mark Shipped. Mark Delivered after checking actual delivery evidence. Shipment/delivery timestamps record when the operator entered the event, not automatically obtained carrier timestamps.
6. Cancel unshipped gifts with a reason, or record a return after shipment/delivery. History remains available. Do not contact/Declined and inactive collaborations suppress new approval/ready/shipment actions. Delivery/return records can still capture what already happened.

Gift records do not reserve/deduct inventory, create platform orders, purchase labels, send products or post financial entries. Estimated gift costs are separate from customer sales. Existing expense/fulfillment operations remain the actual execution systems. All product-line and gift transitions retain actor and encrypted audit evidence; stale forms are rejected.

## Temporary codes and referral links

Record an existing merchant-created code on the collaboration. It needs full discount terms, eligible products, minimum spend, usage/per-customer limits, stacking policy, start/end timestamps, a destination on the campaign storefront host and an evidence URL. A reviewer confirms the actual merchant settings for 24 hours. Changes clear verification. Codes are unique per workspace/merchant host across both group and influencer offers; a database constraint ensures an offer has exactly one recipient type.

**Copy code and referral link** checks that the offer is active, freshly verified, tied to an Active collaboration and a contactable influencer. Expired/unverified codes cannot be copied through that workflow. Rupert's expiry does not deactivate a code in the merchant store; configure the merchant expiry to match. Automatic merchant-code creation/update/revocation remains a separate phase and requires explicit owner sign-off under `AGENTS.md`.

An Active collaboration also has a standalone referral URL. Both URL types retain approved storefront destinations and replace UTM parameters with campaign/influencer/collaboration-or-offer identifiers. They contain no contact details. Supported copy actions are audited. These are ordinary storefront URLs; Rupert does not provide a public redirect, count clicks, attribute orders, calculate commissions or prove who redeemed a shared code in this release.

## Documentation

Save briefs, product instructions, agreements, offer terms, disclosure guidance, content reuse permission records or outcomes on a collaboration. The new-document form starts with a brief outline. Write plain text and optionally link to a public HTTPS supporting document; files are not fetched or uploaded. Content and source URLs are encrypted at rest.

Choose **Marketing readers** or **Restricted contacts access**. Restricted titles/content/history are omitted from collaboration lists and blocked at direct URLs unless the reader has contacts access. Every save creates an immutable numbered revision and resets review. Review records the operator and date for the current revision; it does not execute a signature, obtain permission, or verify an external party's acceptance. Put the actual permission/acknowledgement evidence in the document or supporting reference. Older versions remain accessible, with the latest 50 listed. No creator self-service portal or automatic document delivery is implemented.

## Controls and release

See the [October 16 SER8 deployment record](influencer-cms-deployment-2026-10-16.md) for the deployed revision, validation and recovery checkpoint.

Profiles, collaborations, gifts, documents, offers and audit records are tenant-scoped. Ownership/association checks reject foreign workspace IDs. Read/write/review/contacts permissions apply to direct routes as well as navigation. Private form containers are filtered from request logs. Contacts, addresses, tracking details, interaction bodies, document content/source links and CMS audit payloads are encrypted. The UI shows only audit metadata to readers without contacts access. No export or public contact/document endpoint is added.

The migration adds eight CMS tables and an optional collaboration reference on existing offers. Existing community offers retain their recipient and reviewed reply fingerprints; new influencer offers cannot be attached to community reply drafts. Rehearse migration/rollback/reapply against a production copy before live release, preserve all prior-table counts, and deploy on top of the latest SER8 revision. After collecting influencer records, compatible code rollback should keep the new tables; reverting the migration would discard those records and cannot preserve influencer-only offers.

Directory pages contain 30 prospects. Collaboration/profile sections show the latest 30 entries, conversations the latest 50, and activity history the latest 20. Selectors show up to 200 workspace entries; product search shows the first 50 matches, so refine the query. Gifts allow up to 100 distinct product variants. These bounds are shown in the UI.
