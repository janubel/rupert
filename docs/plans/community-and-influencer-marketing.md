> Historical implementation plan retained during repository reconciliation. Several phases are already deployed; use [issue #54](https://github.com/techmore/rupert/issues/54) for remaining discovery and attribution work.

# Community discovery and influencer CMS implementation plan

Status: proposed; documentation only. Tracking: [issue #54](https://github.com/techmore/rupert/issues/54). Prepared 2026-10-15 against repository commit `015b24a`.

## Product outcome and first release

Add an optional **Marketing** workspace in Rupert. Operators find relevant discussions, review contextual replies with group-specific offers, and track influencers they want to send products to. The influencer CMS holds the relationship, campaign content, product gifts, temporary discount codes, referral links, and supporting documentation in one place.

Start with thread discovery and reply review. The first usable release lets an operator save a thread, assess its relevance, choose an existing verified group offer, review a reply, copy it for manual publication, and record the published URL. Build the influencer directory next using the same campaigns and offers. Add provider automation after those workflows work end to end.

Proposed pilot defaults: one workspace, three groups, ten influencer prospects, and operator-selected product topics. These are adjustable starting limits, not selected communities, approved offers, or launch commitments. Initial code handling records existing merchant-created codes; automatic code creation comes later. Referral links initially provide campaign URLs, with click tracking added in its own phase.

## Fit with the existing application

| Existing seam | Implementation use |
| --- | --- |
| [Module conventions](../modules.md) | Namespaced `Marketing` models under `web/app/modules/marketing/`, controllers, Pundit policies, and existing Tailwind/Turbo views. |
| `web/app/models/module_registry.rb` | Register Marketing and its pages in a single navigation area; hide the optional module when disabled. |
| `web/app/models/concerns/tenant_scoped.rb`, `User`, `ModulePolicy` | Require tenant ownership, explicit action permissions, and matching tenant IDs on associations. |
| `web/config/recurring.yml`, Active Job / Solid Queue | Bounded discovery runs, offer reconciliation, and follow-up tasks; pass tenant IDs and clear `Current` context after each job. |
| `web/app/services/env_store.rb`, `ActivityLogger` | Reuse tenant credential storage and activity conventions; add versioned marketing events for review evidence. |
| `web/app/services/shopify_client.rb` | Reuse the client pinned to Admin API `2026-07` for discount readback and later approved mutations. |
| `CatalogSyncer`, `CanonicalOrderImporter`, `Core::Order` | Reuse product identities and canonical orders; extend ingestion for discount attribution before reporting conversions. |

There is no existing influencer/campaign CMS in the inspected code. Existing `referral_domain` fields describe Rupert workspace signup attribution; create separate commerce referral records. The Shopify order query does not currently request discount codes or customer journey attribution, so existing sales reports cannot establish campaign conversions.

## Operator flows

### Discover threads and review replies

1. Create a community record: platform/group URL, topic include/exclude terms, promotion rules and source, rule review date, campaign, owner, and discovery method.
2. Save URLs manually first. Add one read-only source adapter once access is confirmed. Normalize each result into a thread record with external ID, canonical URL, title, short relevant excerpt, source/group, posted/fetched timestamps, and relevance explanation. Show source failures and last successful discovery.
3. Triage the queue by topic, recency, group, status, and assigned reviewer. Mark relevant, dismiss with reason, or snooze. Distinguish source retrieval from operator-entered notes; freshness is visible.
4. Draft a useful reply grounded in the actual discussion. Attach the group campaign, verified offer, and referral link. Show affiliation wording and expiry alongside the draft. AI assistance is optional and drafts only; imported text is untrusted content and cannot trigger actions or change instructions.
5. Submit an exact revision for review. Reviewer sees thread context, group rules, reply text, offer terms, destination, and previous contact history together. Approve, request changes, or reject with a note.
6. Copy the approved revision for manual publication. Require an active, verified offer at copy time. Record who published it, when, the reply URL, and whether the published wording changed. Changed wording needs a fresh review; an approved draft is not evidence that a reply was posted.

Reply states: `draft → pending_review → approved → published`; review can return to `draft` or end in `rejected`. An edit to text, group, offer terms, link destination, or material thread context invalidates approval. Add `removed` to track moderator/author removal and suppress repeat contact. Recheck eligibility if a thread is locked, deleted, stale, or no longer allows the offer. Clear brand affiliation and group promotion rules belong in review. Do not fabricate experiences or endorsements.

### Influencer CMS and product gifts

Directory fields: name/handle, platform profiles, audience/topic fit, public business contact, relationship owner, source, priority, stage, notes, next follow-up, and contact preferences. Audience size is dated operator/provider evidence, not a guaranteed live metric.

Relationship stages: `prospect → shortlisted → contacted → interested → active → completed`, with `declined` and `do_not_contact` terminal alternatives. Store communication history and drafts; operators send outreach themselves in the initial release. A local status change never sends a message.

Each campaign engagement connects an influencer to a brief, proposed products, temporary offer, referral links, expected content/dates, and evidence URLs. Keep relationship status, individual gift status, and deliverable status separate so repeated collaborations remain understandable.

Gift workflow: `proposed → approved → ready_to_ship → shipped → delivered`, with cancelled/returned exceptions. Record exact product/variant, quantity, estimated product and shipping cost, recipient-confirmed shipping details, carrier/tracking, and handoff notes. Restrict and encrypt addresses/contact details. Only mark shipped from recorded shipment evidence. Initially log shipment performed through the current fulfillment process; local gift records do not reserve stock, decrement inventory, buy labels, or create platform orders. Any later inventory/fulfillment integration needs its own design and owner approval for platform writes.

The CMS also provides versioned documents linked to influencer, engagement, or campaign: briefs, product instructions, approved wording, offer terms, gifting/affiliate disclosure guidance, agreements, permission to reuse content, content URLs, and outcome notes. Start with sanitized Markdown and external document references; keep private documents behind authenticated access. Track document owner, revision, review date, and acknowledgement when needed. Public media reuse requires recorded permission. File upload storage/scanning and a creator self-service portal are later additions.

### Temporary codes and referral links

Use a common campaign/offer service for group and influencer offers. An offer has exactly one recipient type (community or influencer), campaign, merchant account, code, discount type/value, currency where applicable, eligible products, minimum spend, redemption limits, per-customer restrictions, stacking policy, and mandatory start/end timestamps. Display dates in the workspace timezone and store UTC. Give each campaign-recipient offer a distinct code; do not recycle old codes between recipients.

Separate local workflow (`draft`, `approved`, `sync_pending`, `verified`, `sync_failed`, `revocation_pending`, `revoked`) from provider-derived scheduled/active/expired state. An offer becomes shareable only after provider readback confirms the exact terms and current validity. Existing merchant-created offers can be verified before automated activation exists. Local expiry is not proof that a merchant-side code stopped working.

For later Shopify automation, use an adapter around verified Admin API operations, record provider ID/readback and actor-approved terms, and distinguish transport errors from provider validation errors. On an ambiguous create timeout, reconcile by code before retrying to avoid duplicate creation. Changed terms invalidate prior activation approval. Shopify/Square mutations require explicit owner sign-off under [AGENTS.md](../../AGENTS.md); approving a reply alone does not authorize merchant writes.

Each referral link belongs to an engagement or community campaign and has an opaque token, approved storefront destination, UTM source/medium/campaign/content, optional offer, and active dates. Use a configured public HTTPS base URL; do not derive shared links from an arbitrary request host. Initial release can save validated storefront URLs with UTM parameters. Later `/r/:token` redirects record a bounded click event and forward to a server-stored, allowlisted merchant destination. Never accept arbitrary redirect targets or put recipient contact details in URLs. Treat preview/bot requests separately; click counts are estimates, not verified unique people. Expired links can redirect to a normal product page without advertising an expired offer.

## Proposed records and invariants

Introduce records per phase rather than migrating everything at once.

| Record | Main responsibility |
| --- | --- |
| `Marketing::Campaign` | Objective, products, owner, dates, budget, status. |
| `Community`, `DiscoveryRun`, `Thread` | Group configuration, source cursor/errors, deduplicated discussion and triage history. |
| `ReplyDraft`, `ReplyRevision`, `ReviewEvent` | Exact reviewed content/offer snapshot, decisions, publication evidence. |
| `Influencer`, `Engagement`, `Interaction` | Prospect directory, campaign collaboration, communication log/follow-ups. |
| `ProductGift`, `ProductGiftItem` | Gift lifecycle, product quantities/costs, shipment evidence; no implicit stock mutation. |
| `Document`, `DocumentRevision` | Linked brief/instructions/agreement and immutable revision history. |
| `Offer`, `ReferralLink`, `ClickEvent` | Shared offer lifecycle, provider identity, tracking links and events. |
| `OrderAttribution`, `MarketingEvent` | Campaign evidence for canonical orders and actor/versioned workflow history. |

All business records require non-null `tenant_id`, indexed tenant/status/date queries, foreign keys, and same-tenant association validation. Unique thread identity is tenant + platform + external ID (canonical URL fallback); repeated discovery updates freshness without resetting review. Codes must be unique per tenant + merchant account after normalization. Provider discount IDs and link tokens require unique constraints. Use optimistic locking for editing and transactions for review transitions; retain the reviewed snapshot independently of mutable documents/offers.

Add `marketing.read`, `marketing.write`, `marketing.review`, `marketing.offers.activate`, and a separate private-contact permission to the existing catalog/policies. Default access to workspace administrators; allow explicit delegation. Require the actor to remain active/authorized at action time. Preserve existing explicit permission overrides. CSV exports, dashboard/search results, cached pages, document references, and background jobs must follow the same tenant and permission boundaries. Public token lookup is a narrow exception that returns only its stored redirect destination, never private campaign or influencer records.

## Discovery and reporting contracts

Source adapters need configured access, bounded pagination/cursors, rate limits, timeouts/backoff, deduplication, and per-run counts/errors. Fetch only configured hosts; block private/local network URLs and unsafe redirects for manual URL retrieval. Begin with relevance rules that show matched topics and rejection reasons; add model scoring after operators can compare it with their own decisions. Keep short excerpts and source links, support deletion, and set retention per source before ingestion.

Do not assume search results provide permission to crawl a platform. Reddit commercial data access is a dependency to resolve before an automated Reddit adapter; manual URL entry remains useful while provider access is arranged. Choose the first connector from sources actually available to the merchant rather than promising every social network.

Extend the Shopify import with discount-code evidence and, where available, journey/UTM evidence. Persist attribution alongside canonical orders, idempotently by tenant/source/order/evidence identity; preserve original evidence when reclassifying a campaign. A code redemption is stronger evidence than a click. A shared code does not prove group membership or that a particular reply caused the order. Conflicting link/code signals remain visible. Pick one primary attribution for aggregate order/revenue totals; keep secondary signals without double counting. Missing evidence stays unattributed.

Report reviewed/published/removed replies, influencer stages, gifts shipped and costs, click estimates, code redemptions, attributed paid orders, refunds/cancellations, and net attributed revenue by group/influencer/campaign. Define revenue and currency treatment explicitly; do not label revenue as profit. Separate gift costs from customer sales and do not create financial ledger postings from estimated costs. Link to existing expenses when actual costs are recorded. Display coverage window, last sync, and missing data; use estimates rather than a guaranteed ROI figure. Affiliate commission calculation/payouts are a later scope decision.

## Implementation order and acceptance

| Delivery | Scope | Acceptance before moving on |
| --- | --- | --- |
| 1. Thread and reply review MVP | Optional Marketing module, campaigns/groups, manual URL intake, triage queue, versioned replies/review, record existing group code/terms, validated UTM links, manual publication log. | Operator completes save → triage → draft → approve → copy → record URL. Duplicate discovery/contact is visible; stale approval cannot be copied; no external posting occurs. Verify an existing code through readback or dated merchant evidence with an explicit freshness limit. |
| 2. Read-only discovery | One authorized source adapter, scheduled runs, cursors, relevance explanation, retention and run health UI. | A bounded run yields useful review candidates; repeated runs create no duplicates; 429/auth/deletion failures show actionable status and do not flood the queue. |
| 3. Influencer CMS | Directory, engagements, interaction log, follow-ups, versioned documents, product gifts, existing temporary codes/referral URLs. | Operator tracks one prospect through a documented collaboration and gift shipment, with separate content status and restricted contact data. No unsolicited message or inventory write is triggered. |
| 4. Discount and link services | Provider verification and explicitly authorized activation/revocation, expiry reconciliation, public referral redirect/click tracking. | Sandbox-approved code reads back correct terms; expiry, collision, rejection, timeout recovery, retries and revocation work; public links cannot expose private records or redirect off allowlist. |
| 5. Attribution and pilot | Discount evidence ingestion, order attribution, reports, operating docs, controlled pilot. | Replayed imports do not double count; multi-code orders, conflicts, refunds and unknown attribution display correctly. Complete the pilot review before adding more sources or posting automation. |

Deliver each row as a separate reviewed PR (split further where needed). This plan does not schedule jobs or enable a feature in production. Automated social posting, outreach sending, creator portals, commission payouts, and automatic gift fulfillment are later work.

## Verification, rollout, and documentation

Implementation tests must cover cross-tenant record/link/association access, read/write/reviewer/private-contact permissions, stale/replayed approvals, duplicate discovery, malicious URLs and stored content rendering, job tenant cleanup, provider retries, expired/unverified offers, and attribution/refund replay. Exercise workflows on the SQLite CI adapter. Test external adapters with recorded fixtures and explicit merchant-approved sandbox writes; do not use live accounts for routine tests.

Add a per-workspace feature flag, bounded queues/pages/excerpts, and connector toggles. Pilot with manual publication and a small operator-reviewed campaign. Track reviewer usefulness, time per approved reply, community response, and resulting redemptions; compare gift costs and attributable sales for the influencer pilot. Disable discovery/activation independently if failures rise, retain history, and reconcile remote offers during rollback because disabling Rupert does not revoke merchant discounts.

Ship operator docs for discovery setup, reply review, influencer onboarding, product gifting, offer activation/expiry, referral attribution limits, and campaign reporting. Provide templates for briefs, product instructions, approved reply examples, disclosure wording, and permission records. Update `docs/modules.md`, page guides, and the product roadmap catalog only when code exists, then regenerate the product site. Keep planned capability distinct from verified deployment.

Before implementation, resolve the initial product/topic list, three pilot groups and their rules, available source access, first influencer shortlist, merchant/storefront domain, offer limits and duration, reviewers, gift budget/process, and retention periods. Suggested defaults here are adjustable; they do not authorize provider access, publication, or platform writes.

## Verified integration references

Reviewed 2026-10-15; recheck when implementing.

- [Shopify discountCodeBasicCreate, Admin API 2026-07](https://shopify.dev/docs/api/admin-graphql/2026-07/mutations/discountCodeBasicCreate): code-based amount/percentage discounts require `write_discounts`.
- [DiscountCodeBasicInput](https://shopify.dev/docs/api/admin-graphql/2026-07/input-objects/DiscountCodeBasicInput): planned timing, restrictions and combination settings must map to supported input fields.
- [discountCodeDeactivate](https://shopify.dev/docs/api/admin-graphql/2026-07/mutations/discountCodeDeactivate): provider-side deactivation path.
- [Shopify Order](https://shopify.dev/docs/api/admin-graphql/2026-07/objects/Order): discount-code and customer journey fields are candidate attribution evidence; availability and order-access coverage need verification.
- [Reddit Data API Terms](https://redditinc.com/policies/data-api-terms): commercial access requires a separate agreement. This is an adapter dependency, not a dependency for the manual review queue.
- [Existing social automation research](../research/SOCIAL_AUTOMATION_OPTIONS.md): prior context; dated platform/tool claims need fresh verification before implementation.
