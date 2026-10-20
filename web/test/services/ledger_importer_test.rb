# frozen_string_literal: true

require 'test_helper'

class LedgerImporterTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  def shopify_node(id: 'gid://shopify/Order/500', amount: '63.60')
    { 'id' => id, 'name' => '#1500', 'createdAt' => '2026-10-01T12:00:00Z', 'displayFinancialStatus' => 'PAID',
      'currentTotalPriceSet' => { 'shopMoney' => { 'amount' => amount, 'currencyCode' => 'USD' } },
      'lineItems' => { 'nodes' => [{ 'id' => 'gid://shopify/LineItem/1', 'title' => 'Tea', 'quantity' => 2 }, { 'id' => 'gid://shopify/LineItem/2', 'title' => 'Mug', 'quantity' => 1 }],
                       'pageInfo' => { 'hasNextPage' => false } } }
  end

  test 'from_shopify_orders! mirrors each order as a ledger entry in exact cents and feeds the canonical store' do
    assert_equal 1, LedgerImporter.from_shopify_orders!([shopify_node])
    entry = LedgerEntry.find('shopify:gid://shopify/Order/500')
    assert_equal 6360, entry.grossCents
    assert_equal 'shopify', entry.source
    assert_equal '#1500', entry.orderName
    assert_equal 3, entry.lineItems
    assert_equal 'Tea, Mug', entry.summary
    assert_equal 'PAID', entry.status
    assert Core::Order.exists?(source: 'shopify', source_order_id: 'gid://shopify/Order/500')
  end

  test 'from_square_orders! takes integer cents as-is and tolerates a bad timestamp' do
    orders = [{ 'id' => 'sq-1', 'state' => 'COMPLETED', 'created_at' => '2026-10-02T10:00:00Z',
                'total_money' => { 'amount' => 1250, 'currency' => 'USD' }, 'line_items' => [{ 'name' => 'Cream', 'quantity' => '1' }] },
              { 'id' => 'sq-2', 'state' => 'COMPLETED', 'created_at' => 'not-a-time', 'total_money' => { 'amount' => 5 }, 'line_items' => [] }]
    assert_equal 2, LedgerImporter.from_square_orders!(orders)
    assert_equal 1250, LedgerEntry.find('square:sq-1').grossCents
    assert_equal 'SQ-sq-1', LedgerEntry.find('square:sq-1').orderName
    assert_in_delta Time.current, LedgerEntry.find('square:sq-2').occurredAt, 5.seconds
  end

  test 'a re-import updates in place and never overwrites a row owned by another workspace' do
    LedgerImporter.from_shopify_orders!([shopify_node])
    LedgerImporter.from_shopify_orders!([shopify_node(amount: '70.00')])
    assert_equal 7000, LedgerEntry.find('shopify:gid://shopify/Order/500').grossCents
    assert_equal 1, LedgerEntry.where(sourceOrderId: 'gid://shopify/Order/500').count

    other = Tenant.create!(name: 'Other', subdomain: 'otherco')
    LedgerEntry.unscoped.where(id: 'shopify:gid://shopify/Order/500').update_all(tenant_id: other.id)
    assert_equal 0, LedgerImporter.upsert!([{ id: 'shopify:gid://shopify/Order/500', source: 'shopify', sourceOrderId: 'gid://shopify/Order/500',
      orderName: 'x', occurredAt: Time.current, syncedAt: Time.current, currency: 'USD', grossCents: 1, status: 'PAID', lineItems: 0, summary: '' }])
    assert_equal other.id, LedgerEntry.unscoped.find('shopify:gid://shopify/Order/500').tenant_id
  end
end
