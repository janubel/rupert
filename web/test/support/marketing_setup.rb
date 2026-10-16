# frozen_string_literal: true

module MarketingSetup
  def setup_marketing
    @tenant = tenants(:default_tenant)
    @actor = users(:regular_user)
    Current.user = @actor
    FeatureFlag.set(:marketing, true)
    @campaign = Marketing::Campaign.create!(name: 'Community pilot', storefront_url: 'https://shop.herbalhealershcb.com', topics: 'herbal tea')
    @community = Marketing::Community.create!(campaign: @campaign, name: 'Tea group', url: 'https://www.reddit.com/r/tea',
      include_terms: "herbal, tea", exclude_terms: 'giveaway', promotion_rules: 'Disclose affiliation; promotions only in offer threads.',
      rules_url: 'https://www.reddit.com/r/tea/about/rules', rules_checked_at: Time.current)
    @offer = Marketing::Offer.create!(community: @community, code: 'TEA10', terms: '10% off tea; minimum $20; one use per customer; no stacking.',
      destination_url: 'https://shop.herbalhealershcb.com/collections/tea?utm_source=old', starts_at: 1.hour.ago, ends_at: 2.days.from_now,
      evidence_url: 'https://admin.shopify.com/store/merchant/discounts/123', verified_at: Time.current, verified_by_id: @actor.id)
    @thread = Marketing::Thread.create!(community: @community, url: 'https://www.reddit.com/r/tea/comments/123/herbal/?utm_source=share#reply',
      title: 'Herbal tea experiences', excerpt: 'What herbal tea do you enjoy?', status: 'relevant', checked_at: Time.current)
  end

  def draft_reply
    reply = Marketing::Reply.new(thread: @thread)
    Marketing::ReplyWorkflow.call(reply, action: 'save', actor: @actor,
      attributes: { body: 'Here is how we brew this tea.', affiliation: 'I work with Herbal Healers.', offer_id: @offer.id })
    reply
  end

  def transition(reply, action, **options)
    Marketing::ReplyWorkflow.call(reply, action: action, actor: @actor, version: reply.reload.lock_version, **options)
  end
end
