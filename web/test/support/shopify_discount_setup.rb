# frozen_string_literal: true

require_relative 'influencer_cms_setup'

module ShopifyDiscountSetup
  include InfluencerCmsSetup

  def setup_shopify_discounts
    setup_influencer_cms
    @api = mock('discount api')
    Marketing::ShopifyDiscountApi.stubs(:new).returns(@api)
    @api.stubs(:shop_domain).returns('creator-test.myshopify.com')
    @shop = { 'id' => 'gid://shopify/Shop/123', 'myshopifyDomain' => 'creator-test.myshopify.com',
              'currencyCode' => 'USD', 'primaryDomain' => { 'url' => @campaign.storefront_url } }
    @api.stubs(:shop).returns(@shop)
  end

  def discount_attributes
    { code: 'CREATOR15', kind: 'percentage', value: '15', minimum_subtotal: '20.50', usage_limit: '100', once_per_customer: '1',
      starts_at: 1.hour.ago.iso8601, ends_at: 7.days.from_now.iso8601 }
  end

  def discount_draft(attributes = {})
    Marketing::ShopifyDiscountWorkflow.draft(@engagement, actor: @actor, attributes: discount_attributes.merge(attributes))
  end

  def discount_node(record)
    input = record.input
    benefit = input.dig('customerGets', 'value')
    value = if benefit['percentage']
      { '__typename' => 'DiscountPercentage', 'percentage' => benefit['percentage'] }
    else
      { '__typename' => 'DiscountAmount', 'amount' => { 'amount' => benefit.dig('discountAmount', 'amount'), 'currencyCode' => record.currency }, 'appliesOnEachItem' => false }
    end
    minimum = input.dig('minimumRequirement', 'subtotal', 'greaterThanOrEqualToSubtotal')
    { 'id' => 'gid://shopify/DiscountCodeNode/456', 'codeDiscount' => {
      '__typename' => 'DiscountCodeBasic', 'title' => input['title'], 'startsAt' => input['startsAt'], 'endsAt' => input['endsAt'],
      'status' => 'ACTIVE', 'usageLimit' => input['usageLimit'], 'appliesOncePerCustomer' => input['appliesOncePerCustomer'],
      'codes' => { 'nodes' => [{ 'code' => input['code'] }], 'pageInfo' => { 'hasNextPage' => false } },
      'context' => { '__typename' => 'DiscountBuyerSelectionAll' }, 'combinesWith' => input['combinesWith'],
      'customerGets' => { 'items' => { '__typename' => 'AllDiscountItems' }, 'value' => value,
                          'appliesOnOneTimePurchase' => true, 'appliesOnSubscription' => false },
      'minimumRequirement' => minimum ? { '__typename' => 'DiscountMinimumSubtotal', 'greaterThanOrEqualToSubtotal' => { 'amount' => minimum, 'currencyCode' => record.currency } } : nil
    } }
  end

  def activate_discount(record)
    Marketing::ShopifyDiscountWorkflow.activate(record, actor: @actor, version: record.reload.lock_version, confirmed: '1')
  end

  def expect_discount_creation(record)
    @api.expects(:lookup).with(record.offer.code).twice.returns(nil, discount_node(record))
    @api.expects(:create).with(record.input).returns('gid://shopify/DiscountCodeNode/456')
  end
end
