# frozen_string_literal: true

require 'test_helper'

class CanonicalOrderImporterTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
  end

  teardown { Current.tenant = nil }

  def shopify_order(id: 'gid://shopify/Order/123', name: '#1001',
                    customer: { 'id' => 'gid://shopify/Customer/9', 'email' => 'a@b.com', 'firstName' => 'Ada',
                                'lastName' => 'Lovelace' })
    {
      'id' => id,
      'name' => name,
      'createdAt' => Time.current.iso8601,
      'displayFinancialStatus' => 'PAID',
      'paymentGatewayNames' => ['Shopify Payments'],
      'currentTotalPriceSet' => { 'shopMoney' => { 'amount' => '25.00', 'currencyCode' => 'USD' } },
      'currentTotalTaxSet' => { 'shopMoney' => { 'amount' => '2.00', 'currencyCode' => 'USD' } },
      'customer' => customer,
      'lineItems' => {
        'nodes' => [
          {
            'title' => 'CBD Oil',
            'variantTitle' => '500mg',
            'sku' => 'OIL-500',
            'quantity' => 2,
            'originalUnitPriceSet' => { 'shopMoney' => { 'amount' => '10.00' } },
            'originalTotalSet' => { 'shopMoney' => { 'amount' => '20.00' } }
          },
          {
            'title' => 'Gummies',
            'variantTitle' => '30ct',
            'sku' => 'GUM-30',
            'quantity' => 1,
            'originalUnitPriceSet' => { 'shopMoney' => { 'amount' => '5.00' } },
            'originalTotalSet' => { 'shopMoney' => { 'amount' => '5.00' } }
          }
        ]
      }
    }
  end

  def square_order(id: 'sq-abc', customer_id: 'cust-1')
    {
      'id' => id,
      'state' => 'COMPLETED',
      'created_at' => Time.current.iso8601,
      'location_id' => 'L_MAIN',
      'customer_id' => customer_id,
      'total_money' => { 'amount' => 1200, 'currency' => 'USD' },
      'total_tax_money' => { 'amount' => 100, 'currency' => 'USD' },
      'line_items' => [
        {
          'name' => 'CBD Cream',
          'quantity' => '1',
          'base_price_money' => { 'amount' => 1000 },
          'total_money' => { 'amount' => 1000 }
        }
      ],
      'tenders' => [
        { 'id' => 't-1', 'type' => 'CASH', 'amount_money' => { 'amount' => 1200 },
          'created_at' => Time.current.iso8601 }
      ]
    }
  end

  test 'from_shopify! creates canonical order with lines, payment, customer, and tax' do
    count = CanonicalOrderImporter.from_shopify!([shopify_order])
    assert_equal 1, count

    order = Core::Order.find_by(source: 'shopify', source_order_id: 'gid://shopify/Order/123')
    assert order
    assert_equal 'online', order.channel
    assert_equal 'paid', order.status
    assert_equal 2500, order.gross_cents
    assert_equal 200, order.tax_cents

    assert_equal 2, order.order_lines.count
    oil = order.order_lines.find_by(sku: 'OIL-500')
    assert oil
    assert_equal 2, oil.quantity
    assert_equal 2000, oil.line_cents

    assert_equal 1, order.payments.count
    assert_equal 'card', order.payments.first.method
    assert_equal 2500, order.payments.first.amount_cents

    assert order.customer_id.present?
    customer = Core::Customer.find_by(external_id: 'gid://shopify/Customer/9')
    assert customer
    assert_equal 'Ada', customer.first_name
    assert_equal 'a@b.com', customer.email
  end

  test 'from_square! creates canonical order with location, tenders, and customer' do
    CanonicalOrderImporter.from_square!([square_order])
    order = Core::Order.find_by(source: 'square', source_order_id: 'sq-abc')
    assert order
    assert_equal 'pos', order.channel
    assert_equal 'paid', order.status
    assert_equal 'L_MAIN', order.location_id

    assert_equal 1, order.order_lines.count
    assert_equal 'CBD Cream', order.order_lines.first.name

    assert_equal 1, order.payments.count
    assert_equal 'cash', order.payments.first.method
    assert_equal 1200, order.payments.first.amount_cents

    # Square orders carry only a customer ID, so no blank profile is created.
    assert_nil Core::Customer.find_by(external_id: 'cust-1', source: 'square')
    assert_nil order.customer_id
  end

  test 'from_square! links the order to a customer already known from the directory' do
    customer = Core::Customer.create!(source: 'square', external_id: 'cust-1', first_name: 'Ada',
      source_synced_at: Time.current)
    CanonicalOrderImporter.from_square!([square_order])
    order = Core::Order.find_by(source: 'square', source_order_id: 'sq-abc')
    assert_equal customer.id, order.customer_id
  end

  test 'from_square! stores money in cents without inflating (amounts are already cents)' do
    CanonicalOrderImporter.from_square!([square_order])
    order = Core::Order.find_by(source: 'square', source_order_id: 'sq-abc')
    assert_equal 1200, order.gross_cents
    assert_equal 100, order.tax_cents
    assert_equal 1000, order.order_lines.first.unit_cents
    assert_equal 1000, order.order_lines.first.line_cents
  end

  test 'from_shopify! imports fulfillments returned as a plain array (new query shape)' do
    order = shopify_order
    order['fulfillments'] = [
      {
        'id' => 'gid://shopify/Fulfillment/42',
        'status' => 'fulfilled',
        'createdAt' => Time.current.iso8601,
        'trackingInfo' => [
          { 'company' => 'USPS', 'number' => '940011189922', 'url' => 'https://tools.usps.com/track' }
        ]
      }
    ]

    CanonicalOrderImporter.from_shopify!([order])
    record = Core::Order.find_by(source: 'shopify', source_order_id: order['id'])
    assert_equal 1, record.fulfillments.count
    fulfillment = record.fulfillments.first
    assert_equal 'fulfilled', fulfillment.status
    assert_equal 'USPS', fulfillment.tracking_company
    assert_equal '940011189922', fulfillment.tracking_number
  end

  test 'from_shopify! also accepts fulfillments wrapped in a connection (legacy shape)' do
    order = shopify_order
    order['fulfillments'] = {
      'nodes' => [
        {
          'id' => 'gid://shopify/Fulfillment/7',
          'status' => 'in_transit',
          'createdAt' => Time.current.iso8601,
          'trackingInfo' => { 'company' => 'FedEx', 'number' => '1234', 'url' => 'https://fedex.com' }
        }
      ]
    }

    CanonicalOrderImporter.from_shopify!([order])
    record = Core::Order.find_by(source: 'shopify', source_order_id: order['id'])
    assert_equal 1, record.fulfillments.count
    assert_equal 'FedEx', record.fulfillments.first.tracking_company
  end

  test 'is idempotent for the same source order and replaces lines' do
    2.times { CanonicalOrderImporter.from_shopify!([shopify_order]) }
    order = Core::Order.find_by(source: 'shopify', source_order_id: 'gid://shopify/Order/123')
    assert_equal 1, Core::Order.where(source: 'shopify', source_order_id: 'gid://shopify/Order/123').count
    assert_equal 2, order.order_lines.count
    assert_equal 1, order.payments.count
  end

  test 'square gift card and card tenders map to methods' do
    order = square_order
    order['tenders'] = [
      { 'id' => 't1', 'type' => 'GIFT_CARD', 'amount_money' => { 'amount' => 500 },
        'created_at' => Time.current.iso8601 },
      { 'id' => 't2', 'type' => 'CARD', 'amount_money' => { 'amount' => 700 }, 'created_at' => Time.current.iso8601 }
    ]
    CanonicalOrderImporter.from_square!([order])
    payments = Core::Order.find_by(source_order_id: 'sq-abc').payments
    assert_equal %w[card gift_card], payments.map(&:method).sort
  end

  test 'square skips zero-amount tenders instead of failing payment validation' do
    order = square_order
    order['tenders'] = [
      { 'id' => 't-zero', 'type' => 'OTHER', 'amount_money' => { 'amount' => 0 },
        'created_at' => Time.current.iso8601 },
      { 'id' => 't-cash', 'type' => 'CASH', 'amount_money' => { 'amount' => 1200 },
        'created_at' => Time.current.iso8601 }
    ]
    CanonicalOrderImporter.from_square!([order])
    payments = Core::Order.find_by(source_order_id: 'sq-abc').payments
    assert_equal 1, payments.count
    assert_equal 'cash', payments.first.method
    assert_equal 1200, payments.first.amount_cents
  end

  test 'backfill_from_ledger! hydrates from existing ledger entries' do
    LedgerEntry.create!(
      id: 'shopify:gid://shopify/Order/ledger1',
      source: 'shopify',
      sourceOrderId: 'gid://shopify/Order/ledger1',
      occurredAt: Time.current,
      grossCents: 5000,
      status: 'PAID',
      lineItems: 3,
      syncedAt: Time.current,
      currency: 'USD'
    )

    count = CanonicalOrderImporter.backfill_from_ledger!
    assert_equal 1, count
    order = Core::Order.find_by(source_order_id: 'gid://shopify/Order/ledger1')
    assert order
    assert_equal 'paid', order.status
  end
  test 'anonymous Square sales do not invent customer identities and retain existing historical links' do
    assert_no_difference 'Core::Customer.count' do
      CanonicalOrderImporter.from_square!([square_order(id: 'anonymous-sale', customer_id: nil)])
    end
    assert_nil Core::Order.find_by!(source: 'square', source_order_id: 'anonymous-sale').customer_id
    legacy = Core::Customer.create!(source: 'square', external_id: 'legacy-sale', notes: 'Historical context')
    assert_no_difference 'Core::Customer.count' do
      CanonicalOrderImporter.from_square!([square_order(id: 'legacy-sale', customer_id: nil)])
    end
    assert_equal legacy.id, Core::Order.find_by!(source: 'square', source_order_id: 'legacy-sale').customer_id
    assert_equal 'Historical context', legacy.reload.notes
  end

  test 'from_shopify! records platform refunds idempotently and moves a fully refunded order to refunded' do
    node = shopify_order
    node['refunds'] = [{ 'id' => 'gid://shopify/Refund/1', 'createdAt' => Time.current.iso8601,
                         'totalRefundedSet' => { 'shopMoney' => { 'amount' => '10.00', 'currencyCode' => 'USD' } } }]
    CanonicalOrderImporter.from_shopify!([node])
    order = Core::Order.find_by!(source: 'shopify', source_order_id: 'gid://shopify/Order/123')
    assert_equal 1000, order.total_refunded_cents
    assert_equal 'paid', order.status, 'a partial refund keeps the order paid'

    CanonicalOrderImporter.from_shopify!([node])
    assert_equal 1, order.refunds.reload.count, 're-import updates the same refund'

    node['refunds'] << { 'id' => 'gid://shopify/Refund/2', 'createdAt' => Time.current.iso8601,
                         'totalRefundedSet' => { 'shopMoney' => { 'amount' => '15.00', 'currencyCode' => 'USD' } } }
    node['displayFinancialStatus'] = 'REFUNDED'
    CanonicalOrderImporter.from_shopify!([node])
    order.reload
    assert_equal 2500, order.total_refunded_cents
    assert_equal 'refunded', order.status
    assert_equal %w[gid://shopify/Refund/1 gid://shopify/Refund/2], order.refunds.order(:reference).pluck(:reference)
  end

  test 'a refund recorded by hand in Rupert survives platform re-imports' do
    CanonicalOrderImporter.from_shopify!([shopify_order])
    order = Core::Order.find_by!(source: 'shopify', source_order_id: 'gid://shopify/Order/123')
    order.record_refund!(amount_cents: 500, method: 'cash', reason: 'goodwill')
    CanonicalOrderImporter.from_shopify!([shopify_order])
    assert_equal 500, order.reload.total_refunded_cents
    assert_equal 'goodwill', order.refunds.first.reason
  end

  test 'from_square! records refunds from the order refunds array, or from return_amounts when absent' do
    node = square_order
    node['refunds'] = [{ 'id' => 'rf-1', 'status' => 'APPROVED', 'amount_money' => { 'amount' => 200 }, 'created_at' => Time.current.iso8601 },
                       { 'id' => 'rf-2', 'status' => 'REJECTED', 'amount_money' => { 'amount' => 999 } }]
    CanonicalOrderImporter.from_square!([node])
    order = Core::Order.find_by!(source: 'square', source_order_id: 'sq-abc')
    assert_equal 200, order.total_refunded_cents
    assert_equal ['square-refund:rf-1'], order.refunds.pluck(:reference)

    returned = square_order(id: 'sq-ret')
    returned['return_amounts'] = { 'total_money' => { 'amount' => 1200, 'currency' => 'USD' } }
    CanonicalOrderImporter.from_square!([returned])
    order = Core::Order.find_by!(source: 'square', source_order_id: 'sq-ret')
    assert_equal 1200, order.total_refunded_cents
    assert_equal 'refunded', order.status, 'the full sale came back'
  end

  test 'a Shopify POS sale is stored as pos at its store; a web order stays online with no location' do
    store = Location.create!(source: 'shopify', externalId: 'gid://shopify/Location/77', name: 'Main Street')
    CanonicalOrderImporter.from_shopify!([shopify_order(id: 'gid://shopify/Order/901', name: '#901').merge('sourceName' => 'pos',
      'retailLocation' => { 'id' => 'gid://shopify/Location/77' })])
    CanonicalOrderImporter.from_shopify!([shopify_order(id: 'gid://shopify/Order/902', name: '#902').merge('sourceName' => 'web')])
    pos = Core::Order.find_by!(source_order_id: 'gid://shopify/Order/901')
    web = Core::Order.find_by!(source_order_id: 'gid://shopify/Order/902')
    assert_equal ['pos', 'gid://shopify/Location/77', store], [pos.channel, pos.location_id, pos.location]
    assert_equal ['online', nil], [web.channel, web.location_id]
  end
end
