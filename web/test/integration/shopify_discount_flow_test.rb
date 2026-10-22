# frozen_string_literal: true

require 'test_helper'
require_relative '../support/shopify_discount_setup'

class ShopifyDiscountFlowTest < ActionDispatch::IntegrationTest
  include ShopifyDiscountSetup
  setup do
    setup_shopify_discounts
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end
  teardown { Current.reset }

  test 'operator drafts reviews creates and copies a Shopify influencer offer' do
    get marketing_engagement_path(@engagement)
    assert_select 'a', text: 'Add Shopify code'
    get new_marketing_engagement_shopify_discount_path(@engagement)
    assert_response :success
    assert_select 'input[name="discount[ends_at]"][required]'
    @api.expects(:create).never
    post marketing_engagement_shopify_discounts_path(@engagement), params: { discount: discount_attributes.merge(tenant_id: 'foreign', status: 'created', remote_id: 'forged') }
    record = Marketing::ShopifyDiscount.last
    assert_redirected_to marketing_engagement_shopify_discount_path(@engagement, record)
    assert_equal @tenant.id, record.tenant_id
    assert_equal 'draft', record.status
    assert_nil record.remote_id
    get marketing_engagement_shopify_discount_path(@engagement, record)
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_includes response.body, 'creator-test.myshopify.com'
    assert_includes response.body, '20.5 USD'
    assert_select 'input[name="confirmed"][required]'
  end

  test 'creation needs exact confirmation and direct offer edits cannot change Shopify terms' do
    record = discount_draft
    post activate_marketing_engagement_shopify_discount_path(@engagement, record), params: { lock_version: record.lock_version }
    assert_redirected_to marketing_path
    assert_equal 'draft', record.reload.status
    expect_discount_creation(record)
    post activate_marketing_engagement_shopify_discount_path(@engagement, record), params: { lock_version: record.lock_version, confirmed: '1', discount: { value: '99' } }
    assert_redirected_to marketing_engagement_shopify_discount_path(@engagement, record)
    assert_equal 'created', record.reload.status
    assert_equal({ 'percentage' => 0.15 }, record.input.dig('customerGets', 'value'))
    @api.expects(:lookup).with('CREATOR15').returns(discount_node(record))
    post copy_marketing_engagement_offer_path(@engagement, record.offer)
    assert_response :success
    assert_includes response.body, '/discount/CREATOR15?redirect='
    patch marketing_engagement_offer_path(@engagement, record.offer), params: { cms_record: { lock_version: record.offer.reload.lock_version, code: 'ALTERED', terms: 'different' } }
    assert_redirected_to marketing_path
    assert_equal 'CREATOR15', record.offer.reload.code
    get marketing_engagement_path(@engagement)
    assert_select 'a', text: 'Shopify: Created'
    assert_select 'a[href=?]', edit_marketing_engagement_offer_path(@engagement, record.offer), count: 0
    assert_select 'form[action=?]', verify_marketing_engagement_offer_path(@engagement, record.offer), count: 0
  end

  test 'discount creation permission and review permission are enforced on direct routes' do
    record = discount_draft
    @api.expects(:create).never
    @actor.update_permission_overrides!(%w[marketing.read marketing.write marketing.review])
    get new_marketing_engagement_shopify_discount_path(@engagement)
    assert_redirected_to root_path
    post activate_marketing_engagement_shopify_discount_path(@engagement, record), params: { lock_version: record.lock_version, confirmed: '1' }
    assert_redirected_to root_path
    @actor.update_permission_overrides!(%w[marketing.read marketing.write marketing.discounts])
    post activate_marketing_engagement_shopify_discount_path(@engagement, record), params: { lock_version: record.lock_version, confirmed: '1' }
    assert_redirected_to root_path
    @actor.update_permission_overrides!(%w[marketing.read])
    get marketing_engagement_shopify_discount_path(@engagement, record)
    assert_response :success
    assert_select 'input[name="confirmed"]', count: 0
    post refresh_marketing_engagement_shopify_discount_path(@engagement, record)
    assert_redirected_to root_path
  end

  test 'disabled marketing and mismatched collaboration routes reject access' do
    record = discount_draft
    other = Marketing::CmsWriter.write(@influencer.engagements.new(campaign: @campaign), actor: @actor,
      attributes: { title: 'Other', status: 'active', destination_url: @campaign.storefront_url })
    get marketing_engagement_shopify_discount_path(other, record)
    assert_response :not_found
    FeatureFlag.set(:marketing, false)
    get marketing_engagement_shopify_discount_path(@engagement, record)
    assert_response :not_found
  end
end
