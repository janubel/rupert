# frozen_string_literal: true

require 'test_helper'
require_relative '../support/influencer_cms_setup'

class InfluencerCmsFlowTest < ActionDispatch::IntegrationTest
  include InfluencerCmsSetup
  setup do
    setup_influencer_cms
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end
  teardown { Current.reset }

  test 'directory profile collaboration gift and documentation forms render' do
    gift = create_gift
    document = Marketing::DocumentWriter.write(@engagement.documents.new, actor: @actor, attributes: document_attributes)
    paths = [marketing_influencers_path, marketing_influencer_path(@influencer), new_marketing_influencer_path,
      edit_marketing_influencer_path(@influencer), new_marketing_influencer_engagement_path(@influencer),
      marketing_engagement_path(@engagement), edit_marketing_engagement_path(@engagement),
      new_marketing_engagement_offer_path(@engagement), new_marketing_engagement_product_gift_path(@engagement),
      marketing_product_gift_path(gift), edit_marketing_product_gift_path(gift),
      new_marketing_engagement_document_path(@engagement), marketing_document_path(document), edit_marketing_document_path(document)]
    paths.each do |path|
      get path
      assert_response :success, path
      assert_equal 'no-store', response.headers['Cache-Control']
    end
    get marketing_influencers_path, params: { q: 'nonexistent' }
    refute_includes response.body, @influencer.name
    @influencer.update!(next_follow_up_at: 1.hour.ago)
    get marketing_influencers_path, params: { due: '1' }
    assert_includes response.body, @influencer.name
  end

  test 'operator creates a prospect collaboration offer and reviewed campaign document' do
    post marketing_influencers_path, params: { cms_record: { name: 'New prospect', platform: 'Instagram', stage: 'prospect', contact_email: 'prospect@example.org', tenant_id: 'foreign' } }
    prospect = Marketing::Influencer.order(:id).last
    assert_redirected_to marketing_influencer_path(prospect)
    assert_equal @tenant.id, prospect.tenant_id
    post marketing_influencer_engagements_path(prospect), params: { cms_record: { campaign_id: @campaign.id, title: 'New creator campaign', status: 'active', destination_url: @campaign.storefront_url } }
    engagement = Marketing::Engagement.order(:id).last
    assert_redirected_to marketing_engagement_path(engagement)
    post marketing_engagement_offers_path(engagement), params: { cms_record: { code: 'NEWCREATOR10', terms: '10% off tea; one use; no stacking', destination_url: @campaign.storefront_url, starts_at: 1.hour.ago, ends_at: 2.days.from_now, evidence_url: 'https://admin.shopify.com/store/test/discounts/10', verified_at: Time.current } }
    offer = engagement.offers.last
    assert_redirected_to marketing_engagement_path(engagement)
    assert_nil offer.verified_at
    post verify_marketing_engagement_offer_path(engagement, offer), params: { lock_version: offer.lock_version, confirmed: '1' }
    assert_redirected_to marketing_engagement_path(engagement)
    post copy_marketing_engagement_offer_path(engagement, offer)
    assert_response :success
    assert_select 'textarea[readonly]', text: /NEWCREATOR10/
    get edit_marketing_engagement_offer_path(engagement, offer)
    assert_response :success
    post copy_marketing_engagement_path(engagement)
    assert_response :success
    assert_includes response.body, 'utm_source=influencer-'
    post marketing_engagement_documents_path(engagement), params: { cms_record: document_attributes.merge(body: '<script>unsafe()</script> Gift disclosure') }
    document = engagement.documents.last
    assert_redirected_to marketing_document_path(document)
    get marketing_document_path(document)
    assert_includes response.body, '&lt;script&gt;unsafe()&lt;/script&gt;'
    post review_marketing_document_path(document), params: { lock_version: document.lock_version }
    assert_redirected_to marketing_document_path(document)
    assert_equal 'reviewed', document.reload.status
    patch marketing_document_path(document), params: { cms_record: document_attributes.merge(lock_version: document.lock_version, body: 'New instructions') }
    assert_redirected_to marketing_document_path(document)
    assert_equal 2, document.revisions.count
    assert_equal 'draft', document.reload.status
  end

  test 'gift controller tracks manual handoff with explicit shipment confirmations' do
    post marketing_engagement_product_gifts_path(@engagement), params: { cms_record: { currency: 'USD', shipping_details: @influencer.shipping_details } }
    gift = Marketing::ProductGift.last
    assert_redirected_to marketing_product_gift_path(gift)
    post item_marketing_product_gift_path(gift), params: { lock_version: gift.lock_version, item_action: 'add_item', gift_item: { source_variant_id: @variant.id, quantity: 2, unit_cost_cents: 350 } }
    assert_redirected_to marketing_product_gift_path(gift)
    post transition_marketing_product_gift_path(gift), params: { lock_version: gift.reload.lock_version, gift_action: 'approve' }
    assert_redirected_to marketing_product_gift_path(gift)
    post transition_marketing_product_gift_path(gift), params: { lock_version: gift.reload.lock_version, gift_action: 'confirm_recipient', confirmed: '1' }
    assert_redirected_to marketing_product_gift_path(gift)
    post transition_marketing_product_gift_path(gift), params: { lock_version: gift.reload.lock_version, gift_action: 'ready' }
    assert_redirected_to marketing_product_gift_path(gift)
    patch marketing_product_gift_path(gift), params: { cms_record: { lock_version: gift.reload.lock_version, carrier: 'USPS', tracking_number: 'TEST-TRACK', tracking_url: 'https://tools.usps.com/track/test' } }
    assert_redirected_to marketing_product_gift_path(gift)
    post transition_marketing_product_gift_path(gift), params: { lock_version: gift.reload.lock_version, gift_action: 'ship' }
    assert_redirected_to marketing_path
    assert_equal 'ready_to_ship', gift.reload.status
    post transition_marketing_product_gift_path(gift), params: { lock_version: gift.lock_version, gift_action: 'ship', confirmed: '1' }
    assert_redirected_to marketing_product_gift_path(gift)
    assert_equal 'shipped', gift.reload.status
    post transition_marketing_product_gift_path(gift), params: { lock_version: gift.lock_version, gift_action: 'deliver', confirmed: '1' }
    assert_redirected_to marketing_product_gift_path(gift)
    assert_equal 'delivered', gift.reload.status
  end

  test 'noncontact marketing access never renders contact addresses private history or restricted documents' do
    gift = create_gift
    document = Marketing::DocumentWriter.write(@engagement.documents.new, actor: @actor, attributes: document_attributes('restricted').merge(title: 'PRIVATE AGREEMENT', body: 'PRIVATE CONTRACT CONTENT'))
    Marketing::CmsWriter.log_interaction(@influencer, actor: @actor, attributes: { kind: 'email', body: 'PRIVATE INTERACTION CONTENT', occurred_at: Time.current })
    @actor.update_permission_overrides!(%w[marketing.read marketing.write marketing.review])
    [marketing_influencer_path(@influencer), edit_marketing_influencer_path(@influencer), marketing_product_gift_path(gift),
      edit_marketing_product_gift_path(gift), marketing_engagement_path(@engagement)].each do |path|
      get path
      assert_response :success
      %w[PRIVATE creator@example.org].each { |secret| refute_includes response.body, secret }
    end
    get marketing_document_path(document)
    assert_response :redirect
    refute_includes response.body, 'PRIVATE CONTRACT CONTENT'
    patch marketing_influencer_path(@influencer), params: { cms_record: { lock_version: @influencer.lock_version, private_notes: 'Unauthorized edit' } }
    assert_response :redirect
    assert_equal 'PRIVATE CONTACT NOTES', @influencer.reload.private_notes
    post marketing_influencer_interactions_path(@influencer), params: { interaction: { kind: 'email', body: 'Forbidden', occurred_at: Time.current } }
    assert_response :redirect
    assert_equal 1, @influencer.interactions.count
  end

  test 'readers cannot mutate and foreign IDs cannot expose or attach private records' do
    @actor.update_permission_overrides!(%w[marketing.read])
    get marketing_influencers_path
    assert_response :success
    get new_marketing_influencer_path
    assert_response :redirect
    post copy_marketing_engagement_path(@engagement)
    assert_response :redirect
    foreign = Tenant.create!(name: 'Private influencer workspace', subdomain: 'private-influencers')
    other = Marketing::Influencer.create!(tenant_id: foreign.id, name: 'FOREIGN PRIVATE CREATOR')
    get marketing_influencer_path(other)
    assert_response :not_found
    get marketing_influencers_path
    refute_includes response.body, 'FOREIGN PRIVATE CREATOR'
    @actor.update_permission_overrides!(%w[marketing.read marketing.write marketing.contacts])
    post marketing_influencer_engagements_path(other), params: { cms_record: { title: 'Cross workspace', campaign_id: @campaign.id, destination_url: @campaign.storefront_url } }
    assert_response :not_found
  end

  test 'stale profile edits and disabled marketing are blocked and group-code pages ignore influencer offers' do
    offer = create_creator_offer
    version = @influencer.lock_version
    @influencer.update!(stage: 'active')
    patch marketing_influencer_path(@influencer), params: { cms_record: { lock_version: version, stage: 'declined' } }
    assert_redirected_to marketing_path
    assert_equal 'active', @influencer.reload.stage
    get marketing_path
    assert_response :success
    refute_includes response.body, offer.code
    get edit_marketing_offer_path(offer)
    assert_response :not_found
    FeatureFlag.set(:marketing, false)
    get marketing_influencers_path
    assert_response :not_found
    FeatureFlag.set(:marketing, true)
    get marketing_influencer_path(@influencer)
    assert_response :success
  end
end
