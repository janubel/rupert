# frozen_string_literal: true

require 'test_helper'
require_relative '../support/shopify_discount_setup'

class ShopifyDiscountWorkflowTest < ActiveSupport::TestCase
  include ShopifyDiscountSetup
  setup { setup_shopify_discounts }
  teardown { Current.reset }

  test 'draft persists exact immutable terms and influencer linkage without a merchant mutation' do
    @api.expects(:create).never
    record = discount_draft
    assert_equal @engagement.id, record.offer.engagement_id
    assert_nil record.offer.community_id
    assert_equal @shop['id'], record.shop_id
    assert_equal @tenant.id, record.tenant_id
    assert_equal({ 'percentage' => 0.15 }, record.input.dig('customerGets', 'value'))
    assert_equal '20.5', record.input.dig('minimumRequirement', 'subtotal', 'greaterThanOrEqualToSubtotal')
    assert_equal false, record.input.dig('combinesWith', 'orderDiscounts')
    assert_equal false, record.input.dig('customerGets', 'appliesOnSubscription')
    assert_equal 'draft', record.status
    refute record.offer.shareable?
    refute_includes record.request_json, @influencer.contact_email
    refute_includes record.request_json, @influencer.shipping_details
    assert_raises(ActiveRecord::RecordInvalid) { record.update!(request_json: '{}') }
    record.reload
    assert_raises(Marketing::ReplyWorkflow::Invalid) do
      Marketing::InfluencerOfferWriter.write(record.offer, actor: @actor, version: record.offer.lock_version, attributes: { code: 'OTHER' })
    end
    assert_raises(Marketing::ReplyWorkflow::Invalid) do
      Marketing::InfluencerOfferWriter.write(record.offer, actor: @actor, version: record.offer.lock_version, attributes: {}, verify: true)
    end
    encrypted = ActiveRecord::Base.connection.select_value("SELECT request_json FROM marketing_shopify_discounts WHERE id=#{record.id}")
    refute_includes encrypted, 'CREATOR15'
  end

  test 'confirmed creation is read back and sharing applies the code with influencer and campaign attribution' do
    record = discount_draft
    expect_discount_creation(record)
    assert_no_difference ['Core::Order.count', 'ShopifyVariant.count'] do
      activate_discount(record)
    end
    assert_equal 'created', record.reload.status
    assert_equal @actor.id, record.approved_by_id
    assert record.attempted_at
    assert record.checked_at
    assert_equal 'gid://shopify/DiscountCodeNode/456', record.remote_id
    assert record.offer.reload.shareable?
    assert_equal record.admin_url, record.offer.evidence_url
    refute Current.push_confirmed?
    @api.expects(:lookup).with('CREATOR15').returns(discount_node(record))
    copy = Marketing::InfluencerOfferWriter.copy(record.offer, actor: @actor)
    url = URI(copy.lines.last.strip)
    assert_equal '/discount/CREATOR15', url.path
    destination = URI.decode_www_form(url.query).to_h.fetch('redirect')
    assert_includes destination, "utm_source=influencer-#{@influencer.id}"
    assert_includes destination, "utm_content=offer-#{record.offer.id}"
    assert_includes destination, "utm_campaign=campaign-#{@campaign.id}"
    assert Marketing::CmsEvent.where(subject_type: record.class.name, subject_id: record.id, action: 'shopify_creation_confirmed').exists?
  end

  test 'fixed amount and no minimum generate precise store-currency terms' do
    record = discount_draft(kind: 'fixed', value: '7.25', minimum_subtotal: '0', once_per_customer: '0')
    assert_equal '7.25', record.input.dig('customerGets', 'value', 'discountAmount', 'amount')
    assert_equal false, record.input.dig('customerGets', 'value', 'discountAmount', 'appliesOnEachItem')
    refute record.input.key?('minimumRequirement')
    assert_includes record.offer.terms, '7.25 USD'
    assert Marketing::ShopifyDiscountTerms.matches?(record, discount_node(record))
    expect_discount_creation(record)
    activate_discount(record)
    assert record.offer.reload.shareable?
  end

  test 'no confirmation stale form permission removal inactive relationship and expired draft prevent mutation' do
    record = discount_draft
    @api.expects(:create).never
    assert_raises(Marketing::ReplyWorkflow::Invalid) do
      Marketing::ShopifyDiscountWorkflow.activate(record, actor: @actor, version: record.lock_version, confirmed: nil)
    end
    assert_raises(Marketing::ReplyWorkflow::Invalid) do
      Marketing::ShopifyDiscountWorkflow.activate(record, actor: @actor, version: record.lock_version + 1, confirmed: '1')
    end
    @actor.update_permission_overrides!(%w[marketing.read marketing.write marketing.review])
    assert_raises(Pundit::NotAuthorizedError) { activate_discount(record) }
    @actor.update_permission_overrides!(%w[marketing.read marketing.write marketing.discounts])
    assert_raises(Pundit::NotAuthorizedError) { activate_discount(record) }
    @actor.update_permission_overrides!(%w[marketing.read marketing.write marketing.review marketing.discounts])
    @influencer.update!(stage: 'do_not_contact')
    assert_raises(Marketing::ReplyWorkflow::Invalid) { activate_discount(record) }
    @influencer.update!(stage: 'interested')
    travel_to 8.days.from_now do
      assert_raises(Marketing::ReplyWorkflow::Invalid) { activate_discount(record) }
    end
    assert_equal 'draft', record.reload.status
  end

  test 'wrong store identity currency storefront and cross tenant records prevent merchant calls' do
    record = discount_draft
    @api.expects(:create).never
    @shop['id'] = 'gid://shopify/Shop/999'
    assert_raises(Marketing::ReplyWorkflow::Invalid) { activate_discount(record) }
    @shop['id'] = record.shop_id
    @shop['currencyCode'] = 'CAD'
    assert_raises(Marketing::ReplyWorkflow::Invalid) { activate_discount(record) }
    @shop['currencyCode'] = 'USD'
    @shop['primaryDomain']['url'] = 'https://another-store.example.org'
    assert_raises(Marketing::ReplyWorkflow::Invalid) { activate_discount(record) }
    record.tenant_id = 'other-tenant'
    assert_raises(ActiveRecord::RecordNotFound) do
      Marketing::ShopifyDiscountWorkflow.activate(record, actor: @actor, version: record.lock_version, confirmed: '1')
    end
  end

  test 'duplicate submissions and existing unrelated merchant codes are never overwritten' do
    record = discount_draft
    expect_discount_creation(record)
    activate_discount(record)
    assert_raises(Marketing::ReplyWorkflow::Invalid) { activate_discount(record) }
    other = discount_draft(code: 'OTHER15')
    node = discount_node(other)
    node['codeDiscount']['title'] = 'Existing merchant promotion'
    @api.expects(:lookup).with('OTHER15').returns(node)
    activate_discount(other)
    assert_equal 'blocked', other.reload.status
    refute other.offer.reload.shareable?
  end

  test 'timeout remains uncertain and exact read-only recovery never retries the mutation' do
    record = discount_draft
    @api.expects(:lookup).with('CREATOR15').returns(nil)
    @api.expects(:create).once.raises(Marketing::ShopifyDiscountApi::Error, 'Connection timed out; check result.')
    activate_discount(record)
    assert_equal 'uncertain', record.reload.status
    assert_nil record.offer.reload.verified_at
    assert_raises(Marketing::ReplyWorkflow::Invalid) { activate_discount(record) }
    @api.expects(:lookup).with('CREATOR15').returns(nil)
    Marketing::ShopifyDiscountWorkflow.refresh(record, actor: @actor)
    assert_equal 'uncertain', record.reload.status
    @api.expects(:lookup).with('CREATOR15').returns(discount_node(record))
    Marketing::ShopifyDiscountWorkflow.refresh(record, actor: @actor)
    assert_equal 'created', record.reload.status
    assert record.offer.reload.shareable?
  end

  test 'process interruption and local persistence failure leave a recoverable intent' do
    record = discount_draft
    @api.expects(:lookup).with('CREATOR15').returns(nil)
    @api.expects(:create).raises(ActiveRecord::StatementInvalid, 'simulated process interruption')
    assert_raises(ActiveRecord::StatementInvalid) { activate_discount(record) }
    assert_equal 'creating', record.reload.status
    assert_raises(Marketing::ReplyWorkflow::Invalid) { Marketing::ShopifyDiscountWorkflow.refresh(record, actor: @actor) }
    travel_to 3.minutes.from_now do
      @api.expects(:lookup).with('CREATOR15').returns(discount_node(record))
      Marketing::ShopifyDiscountWorkflow.refresh(record, actor: @actor)
      assert_equal 'created', record.reload.status
    end
  end

  test 'external changes deactivation and expiry stop sharing while retaining history' do
    record = discount_draft
    expect_discount_creation(record)
    activate_discount(record)
    node = discount_node(record)
    node['codeDiscount']['customerGets']['value']['percentage'] = 0.90
    @api.expects(:lookup).with('CREATOR15').returns(node)
    assert_raises(Marketing::ReplyWorkflow::Invalid) { Marketing::InfluencerOfferWriter.copy(record.offer, actor: @actor) }
    assert_equal 'blocked', record.reload.status
    assert_nil record.offer.reload.verified_at
    node = discount_node(record)
    node['codeDiscount']['status'] = 'EXPIRED'
    @api.expects(:lookup).with('CREATOR15').returns(node)
    Marketing::ShopifyDiscountWorkflow.refresh(record, actor: @actor)
    refute record.offer.reload.shareable?
    assert_equal 'EXPIRED', record.reload.remote_status
    assert record.remote_json
  end

  test 'readback compares all offer restrictions rather than trusting a matching code' do
    record = discount_draft
    mutations = [
      ->(data) { data['endsAt'] = nil }, ->(data) { data['usageLimit'] = nil },
      ->(data) { data['appliesOncePerCustomer'] = false }, ->(data) { data['combinesWith']['shippingDiscounts'] = true },
      ->(data) { data['customerGets']['items']['__typename'] = 'DiscountProducts' },
      ->(data) { data['context']['__typename'] = 'DiscountCustomers' },
      ->(data) { data['customerGets']['appliesOnSubscription'] = true },
      ->(data) { data['minimumRequirement']['greaterThanOrEqualToSubtotal']['amount'] = '0' },
      ->(data) { data['minimumRequirement']['greaterThanOrEqualToSubtotal']['currencyCode'] = 'CAD' },
      ->(data) { data['codes']['pageInfo']['hasNextPage'] = true }
    ]
    mutations.each do |mutate|
      node = discount_node(record)
      mutate.call(node['codeDiscount'])
      refute Marketing::ShopifyDiscountTerms.matches?(record, node)
    end
  end

  test 'invalid or unbounded amounts dates and codes cannot become drafts' do
    [{ value: '101' }, { value: 'NaN' }, { value: '0' }, { value: '1.234' }, { usage_limit: '0' }, { usage_limit: 'unlimited' },
      { minimum_subtotal: '-1' }, { once_per_customer: 'anything' }, { ends_at: 1.day.ago.iso8601 }, { ends_at: '' }, { starts_at: '' }].each do |bad|
      assert_raises(Marketing::ReplyWorkflow::Invalid) { discount_draft(bad) }
    end
    assert_raises(ActiveRecord::RecordInvalid) { discount_draft(code: '<bad>') }
    assert_raises(ActiveRecord::RecordInvalid) { discount_draft(code: @offer.code) }
    @engagement.update!(status: 'cancelled')
    assert_raises(Marketing::ReplyWorkflow::Invalid) { discount_draft }
  end

  test 'discount referral redirects retain only same origin paths and replace old code parameters' do
    url = Marketing::ReferralUrl.build('https://shop.herbalhealershcb.com/tea?q=green&discount=OLD&utm_source=old#brew', source: 'influencer-1', campaign: 2, content: 'offer-3', discount_code: 'NEW10')
    uri = URI(url)
    assert_equal '/discount/NEW10', uri.path
    redirect = URI.decode_www_form(uri.query).to_h.fetch('redirect')
    assert redirect.start_with?('/tea?')
    assert_includes redirect, 'q=green'
    assert_includes redirect, 'utm_source=influencer-1'
    assert redirect.end_with?('#brew')
    refute_includes redirect, 'discount=OLD'
    assert_raises(Marketing::ReplyWorkflow::Invalid) do
      Marketing::ReferralUrl.build('https://shop.herbalhealershcb.com//evil.org', source: 'i', campaign: 1, content: 'o', discount_code: 'NEW10')
    end
  end
end
