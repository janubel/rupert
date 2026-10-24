# frozen_string_literal: true

require 'test_helper'

class AlertGeneratorTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
  end

  teardown { Current.reset }

  def variant(id, status: 'ACTIVE', quantity: 1, sku: id.upcase)
    product = ShopifyProduct.create!(id: "p-#{id}", title: "#{id} tea", status: status)
    ShopifyVariant.create!(id: "v-#{id}", product: product, sku: sku, title: id, tracked: true, inventoryQuantity: quantity)
  end

  test 'alerts for products no longer sold are closed with the reason; sold products keep theirs' do
    sold = variant('sold')
    archived = variant('archived', status: 'ARCHIVED')
    no_sku = variant('nosku', sku: nil)
    [archived, no_sku].each { |row| StockAlert.create!(shopifyVariantId: row.id, sku: row.sku, quantity: 1, threshold: 5, status: 'open', createdAt: 1.week.ago) }
    StockAlert.create!(shopifyVariantId: 'v-deleted', sku: 'GONE', quantity: 0, threshold: 5, status: 'open', createdAt: 1.week.ago)

    result = AlertGenerator.sync!
    assert_equal 1, result[:created], 'the sold low-stock variant gets its alert'
    assert_equal 3, result[:resolved]
    assert_equal [sold.id], StockAlert.open.pluck(:shopifyVariantId)
    assert_equal ['Closed: no longer sold on Shopify (archived, draft or removed from the catalog)'],
      StockAlert.where(status: 'resolved').distinct.pluck(:note)
  end

  test 'Square alerts are left alone' do
    StockAlert.create!(squareVariationId: 'sq-1', sku: 'SQ', quantity: 0, threshold: 5, status: 'open', createdAt: 1.week.ago)
    AlertGenerator.sync!
    assert_equal 1, StockAlert.open.count
  end
end
