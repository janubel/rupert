# Shopify influencer discount creation

Open **Marketing → Influencers → a collaboration → Create Shopify code**. Marketing must be enabled and the collaboration Active with a contactable influencer.

## Connection and access

Save this workspace's Shopify shop domain, client ID and client secret in **System → Connections**. The creator captures tenant credentials and never falls back to a global/default shop. The connected app needs Shopify's `write_discounts` permission, including its corresponding read access. Declaring the scope in this repository does not change a merchant installation: grant the connected app access in Shopify and complete the required installation/authorization step. Each operation obtains a fresh client-credentials token; no credentials enter offer records or error messages.

Rupert verifies the authenticated shop ID, exact `myshopify.com` domain, currency and primary storefront domain. The campaign storefront must match that primary domain. Changed store/currency/domain blocks creation and verification. This version does not support alternate storefront domains or headless storefront discount application.

Administrators receive `marketing.discounts` by default; explicit role/person overrides remain authoritative. Drafting needs Marketing read/write/discounts access; creation also needs review access. Reading needs Marketing read, and checking/copying needs write. Contacts access remains separate. The Shopify request includes the code, terms and a technical influencer/intent title, never contact email, recipient addresses or conversations.

## Draft, review and create

1. Choose a generated or custom code, percentage or fixed amount, minimum subtotal, total usage limit, per-customer rule, start and required expiry. Amounts use the verified store currency, with at most two decimal places; Shopify performs currency-specific validation. Percentages are greater than zero and at most 100%; total usage is 1 to 1,000,000. Scope is all products/all customers, one-time purchases, no subscriptions, shipping discount or combining with other discounts.
2. Save the draft. This verifies store/access read-only and saves immutable local terms; no merchant discount is created. The offer belongs to the influencer's collaboration and shares code uniqueness with existing group/influencer records.
3. Review the displayed store, currency, full terms, landing page and dates. Check the confirmation for that exact code/store and select **Create this code in Shopify**. The runtime platform-write confirmation guard also protects the mutation.
4. Rupert commits the approved intent before the network call, checks for an existing code, and sends `discountCodeBasicCreate` once. It stores the discount ID and reads the result back. Verification requires the owned intent title, code, amount/percentage, dates, buyer/product/purchase eligibility, minimum and usage/combination limits to match. Existing merchant codes are never overwritten.

Prepare a new draft to change terms. Shopify-managed offers cannot be edited or manually verified through the existing-code form. This release creates codes; automatic update/revocation is separate. Shopify enforces expiry. For urgent deactivation, use **Open code in Shopify**. Do not contact, inactive collaborations and disabling Marketing stop Rupert sharing but do not revoke existing merchant codes.

## Referral link and current state

**Copy code and referral link** checks Shopify again before copying. The link uses `/discount/CODE?redirect=…`; the same-origin campaign landing page retains influencer, campaign and offer UTM identifiers. Existing UTM/discount parameters are replaced. No contact data enters the URL. Shopify applies the code subject to cart eligibility, dates and redemption limits; the link does not guarantee a particular cart qualifies.

Externally changed terms, removed/expired/deactivated codes, wrong-store connections and failed reads block copying. Readbacks/copies are audited, and encrypted remote evidence remains available. Links do not measure clicks, attribute orders or calculate commissions.

## Uncertain results and recovery

Timeouts, malformed responses and interruptions may occur after Shopify accepts a mutation. Creating/Uncertain records never retry mutations automatically. Use **Check Shopify result**, which is read-only; Creating records must be at least two minutes old to let the in-flight call finish. The exact owned result recovers its identity and verification. An absent result stays uncertain: check Shopify before drafting a replacement. Conflicting/changed codes are blocked and never adopted or overwritten. Definitive Shopify user errors become Failed; a subsequent explicit attempt still checks for an existing code first.

The migration adds `marketing_shopify_discounts` with unique offer/request and tenant/shop/remote identities plus foreign keys. Requests, remote snapshots, errors and CMS audit payloads are encrypted. Rehearse migration/rollback/reapply on a production copy and preserve prior data. Keep the additive table for compatible code rollback after real discounts exist. Database rollback does not revoke Shopify discounts. No scheduler creates codes, and tests/deployment do not create real merchant discounts.

## API contract

The operations use the project's pinned **2026-07** Admin GraphQL version and pass Shopify AI Toolkit schema validation:

- [Create a basic code discount](https://shopify.dev/docs/api/admin-graphql/2026-07/mutations/discountCodeBasicCreate)
- [Basic code input](https://shopify.dev/docs/api/admin-graphql/2026-07/input-objects/DiscountCodeBasicInput)
- [Look up a code](https://shopify.dev/docs/api/admin-graphql/2026-07/queries/codeDiscountNodeByCode)
- [Shopify shareable discount links](https://help.shopify.com/en/manual/discounts/managing-discounts#promote-a-discount-using-a-shareable-link)
