# frozen_string_literal: true

require 'test_helper'

class CanonicalInventoryIdentityTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'exact line and variant identities survive reused SKUs and unchanged reimports' do
    node = source_order
    node['lineItems']['nodes'] << source_line(id: 12, variant: 102, quantity: 1)
    CanonicalOrderImporter.from_shopify!([node])
    order = imported_order
    assert order.source_lines_complete
    assert_equal 'PAID', order.source_financial_status
    assert_equal ['gid://shopify/LineItem/11', 'gid://shopify/LineItem/12'], order.order_lines.order(:id).pluck(:source_line_id)
    assert_equal ['gid://shopify/ProductVariant/101', 'gid://shopify/ProductVariant/102'], order.order_lines.order(:id).pluck(:source_variant_id)
    ids = order.order_lines.order(:id).pluck(:id)
    CanonicalOrderImporter.from_shopify!([node])
    assert_equal ids, order.order_lines.reload.order(:id).pluck(:id)
  end

  test 'changed source quantity keeps external identity without relying on local line ID' do
    node = source_order
    CanonicalOrderImporter.from_shopify!([node])
    node['lineItems']['nodes'].first.merge!('quantity' => 3, 'currentQuantity' => 3)
    CanonicalOrderImporter.from_shopify!([node])
    order = imported_order
    assert order.source_lines_complete
    assert_equal 3, order.order_lines.first.quantity
    assert_equal 'gid://shopify/LineItem/11', order.order_lines.first.source_line_id
  end

  test 'missing truncated malformed cancelled and edited source snapshots remain ineligible' do
    mutations = [
      ->(node) { node['lineItems'].delete('pageInfo') },
      ->(node) { node['lineItems']['pageInfo']['hasNextPage'] = true },
      ->(node) { node.delete('cancelledAt') },
      ->(node) { node['cancelledAt'] = '2026-10-14T11:00:00-04:00' },
      ->(node) { node['createdAt'] = '2026-10-14' },
      ->(node) { node['createdAt'] = '2026-02-31T12:00:00Z' },
      ->(node) { node['lineItems']['nodes'].first['quantity'] = '2.5' },
      ->(node) { node['lineItems']['nodes'].first['currentQuantity'] = 1 },
      ->(node) { node['lineItems']['nodes'].first['variant'] = nil },
      ->(node) { node['lineItems']['nodes'].first['variant'] = 'invalid' }
    ]
    mutations.each_with_index do |mutate, index|
      node = source_order(id: index + 1000)
      mutate.call(node)
      CanonicalOrderImporter.from_shopify!([node])
      order = Core::Order.find_by!(source_order_id: node['id'])
      refute order.source_lines_complete, "mutation #{index} must not enable bulk deductions"
    end
  end

  test 'duplicate source line IDs are quarantined without fabricating a SKU-based identity' do
    node = source_order
    node['lineItems']['nodes'] << source_line(id: 11, variant: 102, quantity: 1)
    CanonicalOrderImporter.from_shopify!([node])
    order = imported_order
    refute order.source_lines_complete
    assert_equal [nil, nil], order.order_lines.pluck(:source_line_id)
  end

  test 'raw source refund status remains distinguishable from local order status' do
    node = source_order
    node['displayFinancialStatus'] = 'PARTIALLY_REFUNDED'
    CanonicalOrderImporter.from_shopify!([node])
    assert_equal 'PARTIALLY_REFUNDED', imported_order.source_financial_status
  end

  test 'a failed child replacement rolls back the complete order snapshot' do
    node = source_order
    CanonicalOrderImporter.from_shopify!([node])
    node['currentTotalPriceSet']['shopMoney']['amount'] = '30.00'
    node['lineItems']['nodes'].first.merge!('quantity' => 3, 'currentQuantity' => 3)
    Core::Payment.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid.new(Core::Payment.new))
    assert_raises(ActiveRecord::RecordInvalid) { CanonicalOrderImporter.from_shopify!([node]) }
    order = imported_order
    assert_equal 2000, order.gross_cents
    assert_equal 2, order.order_lines.first.quantity
    assert_equal 2000, order.payments.first.amount_cents
  end

  private

  def imported_order
    Core::Order.find_by!(source: 'shopify', source_order_id: 'gid://shopify/Order/900')
  end

  def source_order(id: 900)
    { 'id' => "gid://shopify/Order/#{id}", 'name' => '#IDENTITY', 'createdAt' => '2026-10-14T10:00:00-04:00',
      'cancelledAt' => nil, 'displayFinancialStatus' => 'PAID', 'paymentGatewayNames' => ['Card'],
      'currentTotalPriceSet' => { 'shopMoney' => { 'amount' => '20.00', 'currencyCode' => 'USD' } },
      'lineItems' => { 'pageInfo' => { 'hasNextPage' => false }, 'nodes' => [source_line] } }
  end

  def source_line(id: 11, variant: 101, quantity: 2)
    { 'id' => "gid://shopify/LineItem/#{id}", 'title' => 'Source item', 'sku' => 'REUSED',
      'variant' => { 'id' => "gid://shopify/ProductVariant/#{variant}" }, 'quantity' => quantity,
      'currentQuantity' => quantity, 'originalUnitPriceSet' => { 'shopMoney' => { 'amount' => '10.00' } },
      'originalTotalSet' => { 'shopMoney' => { 'amount' => (quantity * 10).to_s } } }
  end
end
