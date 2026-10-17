# frozen_string_literal: true

require 'test_helper'

class BusinessSnapshotsIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    post login_path, params: { email: 'admin@example.com', password: 'password' }
    order = Core::Order.create!(source: 'square', source_order_id: 'sq-snap', occurred_at: 2.days.ago, gross_cents: 2500, tax_cents: 0, currency: 'USD')
    order.mark_paid!
    order.payments.create!(method: 'card', amount_cents: 2500, status: 'completed', paid_at: 2.days.ago)
    vendor = Purchasing::Vendor.create!(name: 'Acme Supply')
    Finance::VendorPayment.create!(vendor: vendor, amount_cents: 1200, paid_on: Date.current - 1, method: 'check')
  end

  teardown { Current.reset }

  test 'renders every section with sources, cash and vendors and logs the view' do
    get business_snapshot_path
    assert_response :success
    %w[Sales Products Cash vendors].each { |w| assert_includes response.body, w }
    assert_includes response.body, 'Square'
    assert_includes response.body, '$25.00'
    assert_includes response.body, 'no live connection'
    assert_equal 'private, no-store', response.headers['Cache-Control']
    assert ActivityLog.exists?(tenant_id: @tenant.id, action: 'business_snapshot_viewed')
  end

  test 'data holds figures with no secrets and sources stay separate' do
    data = BusinessSnapshot.new.to_h
    assert_equal 2500, data.dig('sales', 'windows', '30').find { |r| r['source'] == 'square' }['cents']
    assert_equal({ 'card' => 2500 }, data.dig('cash', 'tenders_30d'))
    assert_equal 1200, data.dig('money_out', 'vendor_payments_90d_cents')
    assert_not_includes data.to_json, 'password'
  end

  test 'a dated copy can be saved as unchangeable evidence' do
    assert_difference 'ReconciliationDocument.count', 1 do
      post business_snapshot_path
    end
    doc = ReconciliationDocument.order(:id).last
    assert_equal %w[rupert period_archive], [doc.source, doc.kind]
    assert_equal 'Acme Supply', JSON.parse(doc.original_bytes).dig('vendors', 'vendors', 0, 'name')
    assert ActivityLog.exists?(tenant_id: @tenant.id, action: 'business_snapshot_saved')
  end

  test 'other roles are turned away' do
    users(:regular_user).update!(role: 'reporting')
    get business_snapshot_path
    assert_redirected_to root_path
  end
end
