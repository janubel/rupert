# frozen_string_literal: true

require_relative 'marketing_setup'

module InfluencerCmsSetup
  include MarketingSetup

  def setup_influencer_cms
    setup_marketing
    @influencer = Marketing::CmsWriter.write(Marketing::Influencer.new, actor: @actor,
      attributes: { name: 'Tea Creator', platform: 'YouTube', handle: 'tea-creator', topics: 'herbal tea',
                    profile_url: 'https://www.youtube.com/@tea-creator', stage: 'interested', owner_id: @actor.id,
                    contact_email: 'creator@example.org', shipping_details: 'PRIVATE ADDRESS 123 Test Lane', private_notes: 'PRIVATE CONTACT NOTES' })
    @engagement = Marketing::CmsWriter.write(@influencer.engagements.new(campaign: @campaign), actor: @actor,
      attributes: { title: 'Tea sampler collaboration', status: 'active', destination_url: @campaign.storefront_url + '/tea?utm_source=old', deliverables: 'One honest experience post' })
    product = ShopifyProduct.create!(id: 'cms-product', title: 'Tea sampler', status: 'ACTIVE')
    @variant = ShopifyVariant.create!(id: 'cms-variant', productId: product.id, title: 'Sample box', sku: 'CMS-TEA', price: 12)
  end

  def create_gift
    gift = @engagement.product_gifts.new
    Marketing::GiftWorkflow.run(gift, actor: @actor, action: 'save', attributes: { note: 'Sampler gift', currency: 'USD', shipping_details: @influencer.shipping_details })
    gift
  end

  def gift_action(gift, action, **options)
    Marketing::GiftWorkflow.run(gift, actor: @actor, action: action, version: gift.reload.lock_version, **options)
  end

  def create_creator_offer
    Marketing::InfluencerOfferWriter.write(@engagement.offers.new, actor: @actor,
      attributes: { code: 'CREATOR10', terms: '10% off tea; one use; no stacking', destination_url: @engagement.destination_url,
                    starts_at: 1.hour.ago, ends_at: 1.day.from_now, evidence_url: 'https://admin.shopify.com/store/test/discounts/10' })
  end

  def document_attributes(visibility = 'internal')
    { title: 'Tea brief', kind: 'brief', visibility: visibility, body: 'Honest experience; disclose gifted product.', source_url: 'https://docs.google.com/document/d/test' }
  end
end
