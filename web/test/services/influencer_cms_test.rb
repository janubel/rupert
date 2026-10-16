# frozen_string_literal: true

require 'test_helper'
require_relative '../support/influencer_cms_setup'

class InfluencerCmsTest < ActiveSupport::TestCase
  include InfluencerCmsSetup
  setup { setup_influencer_cms }
  teardown { Current.reset }

  test 'profile contact and audit fields are encrypted while stale edits and cross-tenant parents fail' do
    sql = Marketing::Influencer.connection
    raw = sql.select_one("SELECT contact_email, shipping_details, private_notes FROM marketing_influencers WHERE id=#{@influencer.id}")
    refute_includes raw.values.join, 'creator@example.org'
    refute_includes raw.values.join, 'PRIVATE ADDRESS'
    event = Marketing::CmsEvent.find_by!(subject_type: 'Marketing::Influencer', subject_id: @influencer.id)
    raw_event = sql.select_value("SELECT payload_json FROM marketing_cms_events WHERE id=#{event.id}")
    refute_includes raw_event, 'PRIVATE CONTACT NOTES'
    version = @influencer.lock_version
    Marketing::CmsWriter.write(@influencer, actor: @actor, version: version, attributes: { stage: 'active' })
    assert_raises(Marketing::ReplyWorkflow::Invalid) do
      Marketing::CmsWriter.write(@influencer, actor: @actor, version: version, attributes: { stage: 'declined' })
    end
    foreign = Tenant.create!(name: 'Foreign creator shop', subdomain: 'foreign-creator')
    campaign = Marketing::Campaign.create!(tenant_id: foreign.id, name: 'Foreign', topics: 'tea', storefront_url: 'https://foreign.org')
    assert_raises(ActiveRecord::RecordInvalid) do
      Marketing::CmsWriter.write(@influencer.engagements.new(campaign: campaign), actor: @actor,
        attributes: { title: 'Wrong scope', destination_url: 'https://foreign.org' })
    end
    assert_equal 'active', @influencer.reload.stage
  end

  test 'public marketing writers cannot change private fields or record interactions without contacts access' do
    @actor.update_permission_overrides!(%w[marketing.read marketing.write])
    assert_raises(Pundit::NotAuthorizedError) do
      Marketing::CmsWriter.write(@influencer, actor: @actor, version: @influencer.lock_version, attributes: { contact_email: 'new@example.org' })
    end
    assert_raises(Pundit::NotAuthorizedError) do
      Marketing::CmsWriter.log_interaction(@influencer, actor: @actor, attributes: { kind: 'email', body: 'Private', occurred_at: Time.current })
    end
    Marketing::CmsWriter.write(@influencer, actor: @actor, version: @influencer.lock_version, attributes: { topics: 'updated business context' })
    assert_equal 'creator@example.org', @influencer.reload.contact_email
    assert_equal 'updated business context', @influencer.topics
  end

  test 'interaction history is encrypted immutable and records actual conversation time without sending' do
    Marketing::CmsWriter.log_interaction(@influencer, actor: @actor, attributes: { kind: 'dm', body: 'Private recipient confirmation', occurred_at: 1.hour.ago })
    interaction = @influencer.interactions.last
    assert_equal @actor.id, interaction.actor_id
    raw = Marketing::Interaction.connection.select_value("SELECT body FROM marketing_interactions WHERE id=#{interaction.id}")
    refute_includes raw, 'Private recipient'
    assert_raises(ActiveRecord::ReadOnlyRecord) { interaction.update!(body: 'Changed') }
    assert_raises(ActiveRecord::ReadOnlyRecord) { interaction.destroy! }
    assert_raises(ActiveRecord::RecordInvalid) do
      Marketing::CmsWriter.log_interaction(@influencer, actor: @actor, attributes: { kind: 'email', body: 'Not yet happened', occurred_at: 1.day.from_now })
    end
    assert_requested(:any, /.*/, times: 0)
  end

  test 'gift approval recipient confirmation shipment and return preserve inventory and orders' do
    gift = create_gift
    inventory = InventoryLevel.count
    orders = Core::Order.count
    variant_before = @variant.attributes
    gift_action(gift, 'add_item', attributes: { source_variant_id: @variant.id, quantity: 2, unit_cost_cents: 400 })
    assert_equal 800, gift.reload.estimated_product_cents
    assert_equal @variant.id, gift.items.first.source_variant_id
    assert_raises(Marketing::ReplyWorkflow::Invalid) { gift_action(gift, 'ship') }
    gift_action(gift, 'approve')
    assert_raises(Marketing::ReplyWorkflow::Invalid) { gift_action(gift, 'ready') }
    gift_action(gift, 'confirm_recipient')
    gift_action(gift, 'ready')
    assert_raises(Marketing::ReplyWorkflow::Invalid) { gift_action(gift, 'ship') }
    gift_action(gift, 'save', attributes: { carrier: 'USPS', tracking_number: 'PRIVATE-TRACKING', tracking_url: 'https://tools.usps.com/track/test' })
    gift_action(gift, 'ship')
    gift_action(gift, 'deliver')
    assert gift.reload.delivered_at
    assert_equal 'delivered', gift.status
    gift_action(gift, 'return', note: 'Recipient returned unopened sampler')
    assert_equal 'returned', gift.reload.status
    assert_equal inventory, InventoryLevel.count
    assert_equal orders, Core::Order.count
    assert_equal variant_before, @variant.reload.attributes
    assert_requested(:any, /.*/, times: 0)
  end

  test 'gift product or budget changes after approval and stale item forms are rejected' do
    gift = create_gift
    version = gift.lock_version
    gift_action(gift, 'add_item', attributes: { source_variant_id: @variant.id, quantity: 1 })
    assert_nil gift.reload.estimated_product_cents
    assert_raises(Marketing::ReplyWorkflow::Invalid) do
      Marketing::GiftWorkflow.run(gift, actor: @actor, action: 'add_item', version: version, attributes: { source_variant_id: @variant.id, quantity: 1 })
    end
    gift_action(gift, 'approve')
    assert_raises(Marketing::ReplyWorkflow::Invalid) { gift_action(gift, 'remove_item', item_id: gift.items.first.id) }
    assert_raises(Marketing::ReplyWorkflow::Invalid) { gift_action(gift, 'save', attributes: { shipping_cost_cents: 500 }) }
    assert_equal 1, gift.items.count
    gift_action(gift, 'cancel', note: 'Budget needs revision')
    assert_equal 'cancelled', gift.reload.status
  end

  test 'gift variants must belong to workspace and invalid or duplicate line changes leave history intact' do
    gift = create_gift
    foreign = Tenant.create!(name: 'Foreign gifts', subdomain: 'foreign-gifts')
    foreign_product = ShopifyProduct.create!(tenant_id: foreign.id, id: 'foreign-cms-product', title: 'Foreign product')
    foreign_variant = ShopifyVariant.create!(tenant_id: foreign.id, id: 'foreign-cms-variant', productId: foreign_product.id, sku: 'PRIVATE-SKU', title: 'Foreign product')
    assert_raises(ActiveRecord::RecordNotFound) { gift_action(gift, 'add_item', attributes: { source_variant_id: foreign_variant.id, quantity: 1 }) }
    assert_raises(ActiveRecord::RecordInvalid) { gift_action(gift, 'add_item', attributes: { source_variant_id: @variant.id, quantity: 0 }) }
    gift_action(gift, 'add_item', attributes: { source_variant_id: @variant.id, quantity: 1 })
    assert_raises(ActiveRecord::RecordInvalid) { gift_action(gift, 'add_item', attributes: { source_variant_id: @variant.id, quantity: 1 }) }
    assert_equal 1, gift.items.count
    gift_action(gift, 'remove_item', item_id: gift.items.first.id)
    assert_empty gift.items.reload
    assert_raises(Marketing::ReplyWorkflow::Invalid) { gift_action(gift, 'approve') }
  end

  test 'address edits clear confirmation and shipping details cannot change once ready' do
    gift = create_gift
    gift_action(gift, 'confirm_recipient')
    assert gift.reload.recipient_confirmed_at
    gift_action(gift, 'save', attributes: { shipping_details: 'New confirmed address' })
    assert_nil gift.reload.recipient_confirmed_at
    gift_action(gift, 'add_item', attributes: { source_variant_id: @variant.id, quantity: 1 })
    gift_action(gift, 'approve')
    gift_action(gift, 'confirm_recipient')
    gift_action(gift, 'ready')
    assert_raises(Marketing::ReplyWorkflow::Invalid) { gift_action(gift, 'save', attributes: { shipping_details: 'Another address' }) }
  end

  test 'do not contact and inactive collaborations block new gift handoffs and referral sharing' do
    gift = create_gift
    gift_action(gift, 'add_item', attributes: { source_variant_id: @variant.id, quantity: 1 })
    @influencer.update!(stage: 'do_not_contact')
    assert_raises(Marketing::ReplyWorkflow::Invalid) { gift_action(gift, 'approve') }
    assert_raises(Marketing::ReplyWorkflow::Invalid) { Marketing::CmsWriter.copy_engagement(@engagement, actor: @actor) }
    @influencer.update!(stage: 'active')
    @engagement.update!(status: 'cancelled')
    assert_raises(Marketing::ReplyWorkflow::Invalid) { gift_action(gift, 'approve') }
    assert_raises(Marketing::ReplyWorkflow::Invalid) { Marketing::CmsWriter.copy_engagement(@engagement, actor: @actor) }
  end

  test 'shipping rechecks recipient confirmation after a long ready-to-ship delay' do
    gift = create_gift
    gift_action(gift, 'add_item', attributes: { source_variant_id: @variant.id, quantity: 1 })
    gift_action(gift, 'approve')
    gift_action(gift, 'confirm_recipient')
    gift_action(gift, 'ready')
    gift_action(gift, 'save', attributes: { carrier: 'USPS', tracking_number: 'TEST-TRACKING' })
    travel 91.days do
      assert_raises(Marketing::ReplyWorkflow::Invalid) { gift_action(gift, 'ship') }
      gift_action(gift, 'confirm_recipient')
      gift_action(gift, 'ship')
      assert_equal 'shipped', gift.reload.status
    end
  end

  test 'temporary influencer offers verify before sharing expire and cannot be used in group replies' do
    offer = create_creator_offer
    assert_nil offer.community_id
    assert_equal @engagement.id, offer.engagement_id
    refute offer.shareable?
    assert_raises(Marketing::ReplyWorkflow::Invalid) { Marketing::InfluencerOfferWriter.copy(offer, actor: @actor) }
    Marketing::InfluencerOfferWriter.write(offer, actor: @actor, attributes: {}, version: offer.lock_version, verify: true)
    copy = Marketing::InfluencerOfferWriter.copy(offer, actor: @actor)
    assert_includes copy, 'CREATOR10'
    assert_includes copy, "utm_source=influencer-#{@influencer.id}"
    refute_includes copy, 'utm_source=old'
    assert_raises(Marketing::ReplyWorkflow::Invalid) do
      Marketing::ReplyWorkflow.call(Marketing::Reply.new(thread: @thread), action: 'save', actor: @actor,
        attributes: { body: 'Advice', affiliation: 'Brand', offer_id: offer.id })
    end
    travel 2.days do
      assert_raises(Marketing::ReplyWorkflow::Invalid) { Marketing::InfluencerOfferWriter.copy(offer, actor: @actor) }
    end
    Marketing::InfluencerOfferWriter.write(offer, actor: @actor, version: offer.reload.lock_version, attributes: { terms: 'Updated terms' })
    assert_nil offer.reload.verified_at
    assert_nil offer.verified_by_id
  end

  test 'offer code collision destinations recipient exclusivity and private contact status are enforced' do
    offer = create_creator_offer
    duplicate = @engagement.offers.new
    assert_raises(ActiveRecord::RecordInvalid) do
      Marketing::InfluencerOfferWriter.write(duplicate, actor: @actor, attributes: offer.attributes.symbolize_keys.slice(*Marketing::InfluencerOfferWriter::FIELDS))
    end
    offer.destination_url = 'https://attacker.org/redirect'
    refute offer.valid?
    offer.reload
    offer.community = @community
    refute offer.valid?
    offer.reload
    Marketing::InfluencerOfferWriter.write(offer, actor: @actor, attributes: {}, version: offer.lock_version, verify: true)
    @influencer.update!(stage: 'do_not_contact')
    assert_raises(Marketing::ReplyWorkflow::Invalid) { Marketing::InfluencerOfferWriter.copy(offer, actor: @actor) }
  end

  test 'group reply snapshots keep their legacy offer structure after adding influencer recipients' do
    reply = draft_reply
    transition(reply, 'submit')
    refute JSON.parse(reply.snapshot_json).fetch('offer').key?('engagement_id')
    transition(reply, 'approve')
    assert_includes transition(reply, 'copy'), @offer.code
  end

  test 'documents retain encrypted immutable versions and edits clear review' do
    document = Marketing::DocumentWriter.write(@engagement.documents.new, actor: @actor, attributes: document_attributes)
    Marketing::DocumentWriter.write(document, actor: @actor, attributes: {}, version: document.lock_version, review: true)
    assert_equal 'reviewed', document.reload.status
    revision = document.revisions.first
    raw = Marketing::DocumentRevision.connection.select_value("SELECT body FROM marketing_document_revisions WHERE id=#{revision.id}")
    refute_includes raw, 'Honest experience'
    assert_raises(ActiveRecord::ReadOnlyRecord) { revision.update!(body: 'Overwrite history') }
    assert_raises(ActiveRecord::ReadOnlyRecord) { revision.destroy! }
    version = document.lock_version
    Marketing::DocumentWriter.write(document, actor: @actor, attributes: document_attributes.merge(body: 'Revised brief'), version: version)
    assert_equal [1, 2], document.revisions.order(:number).pluck(:number)
    assert_equal 'draft', document.reload.status
    assert_nil document.reviewed_at
    assert_equal 'Honest experience; disclose gifted product.', revision.reload.body
    assert_raises(Marketing::ReplyWorkflow::Invalid) do
      Marketing::DocumentWriter.write(document, actor: @actor, attributes: document_attributes, version: version)
    end
  end

  test 'restricted documents and private shipping updates require contacts permission' do
    document = Marketing::DocumentWriter.write(@engagement.documents.new, actor: @actor, attributes: document_attributes('restricted'))
    gift = create_gift
    @actor.update_permission_overrides!(%w[marketing.read marketing.write marketing.review])
    assert_raises(Pundit::NotAuthorizedError) do
      Marketing::DocumentWriter.write(document, actor: @actor, version: document.lock_version, attributes: document_attributes('internal'))
    end
    assert_raises(Pundit::NotAuthorizedError) { gift_action(gift, 'save', attributes: { shipping_details: 'Forbidden address' }) }
    assert_raises(Pundit::NotAuthorizedError) { gift_action(gift, 'confirm_recipient') }
    assert_equal 'PRIVATE ADDRESS 123 Test Lane', gift.reload.shipping_details
  end

  test 'failed audit writes roll back profile gift and document mutations' do
    Marketing::CmsEvent.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid)
    assert_raises(ActiveRecord::RecordInvalid) do
      Marketing::CmsWriter.write(@influencer, actor: @actor, version: @influencer.lock_version, attributes: { stage: 'declined' })
    end
    assert_equal 'interested', @influencer.reload.stage
    assert_raises(ActiveRecord::RecordInvalid) { create_gift }
    assert_equal 0, Marketing::ProductGift.count
    assert_raises(ActiveRecord::RecordInvalid) do
      Marketing::DocumentWriter.write(@engagement.documents.new, actor: @actor, attributes: document_attributes)
    end
    assert_equal 0, Marketing::Document.count
    assert_equal 0, Marketing::DocumentRevision.count
  end
end
