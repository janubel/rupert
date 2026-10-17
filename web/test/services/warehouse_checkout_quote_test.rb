# frozen_string_literal: true

require 'test_helper'

class WarehouseCheckoutQuoteTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @share = WarehouseShare.create!(name: 'Quoted vendor')
    @cart = WarehouseCart.create!(tenant_id: Current.tenant_id, share: @share, token: SecureRandom.hex(20))
    @item = @cart.items.create!(tenant_id: Current.tenant_id, share_id: @share.id, variant_id: 'quoted-variant', quantity: 1, unit_cents: 1500, line_cents: 1500)
  end
  teardown { Current.reset }

  test 'signed review expires and rejects tampering or a different cart' do
    token = WarehouseCheckoutQuote.issue(@cart)
    assert WarehouseCheckoutQuote.valid?(token, @cart)
    refute WarehouseCheckoutQuote.valid?("#{token}tampered", @cart)
    refute WarehouseCheckoutQuote.valid?(nil, @cart)
    other = WarehouseCart.create!(tenant_id: Current.tenant_id, share: @share, token: SecureRandom.hex(20))
    refute WarehouseCheckoutQuote.valid?(token, other)
    travel WarehouseCheckoutQuote::LIFETIME + 1.second do
      refute WarehouseCheckoutQuote.valid?(token, @cart)
    end
  end

  test 'prices and quantities must still match the reviewed lines' do
    token = WarehouseCheckoutQuote.issue(@cart)
    @item.update!(quantity: 2, line_cents: 3000)
    refute WarehouseCheckoutQuote.valid?(token, @cart)
    token = WarehouseCheckoutQuote.issue(@cart)
    @item.update!(unit_cents: 1700, line_cents: 3400)
    refute WarehouseCheckoutQuote.valid?(token, @cart)
  end

  test 'checkout addresses and review tokens are filtered from request instrumentation' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal({ 'shipping_name' => '[FILTERED]', 'shipping_address1' => '[FILTERED]', 'shipping_phone' => '[FILTERED]', 'checkout_quote' => '[FILTERED]' },
      filter.filter({ 'shipping_name' => 'Private Person', 'shipping_address1' => 'Private Road', 'shipping_phone' => '555-0100', 'checkout_quote' => 'signed-review' }))
  end
end
