# frozen_string_literal: true

require 'test_helper'

class WarehouseTierTenantTest < ActiveSupport::TestCase
  setup do
    @a = tenants(:default_tenant)
    @b = Tenant.create!(name: 'Other Co', subdomain: "other#{SecureRandom.hex(4)}")
  end

  teardown { Current.tenant = nil }

  def tier_for(tenant, qty, pct)
    Current.set(tenant: tenant) { WarehouseTier.create!(shareId: nil, minQty: qty, discountPercent: pct) }
  end

  test 'tiers are attributed to the current tenant on create' do
    assert_equal @a.id, tier_for(@a, 10, 5).tenant_id
  end

  test 'default tiers are invisible to other tenants' do
    tier_for(@a, 10, 5)
    Current.tenant = @b
    assert_empty WarehouseTier.where(shareId: nil)
    Current.tenant = @a
    assert_equal [10], WarehouseTier.where(shareId: nil).pluck(:minQty)
  end

  test 'one tenant cannot find or destroy another tenants default tier' do
    tier = tier_for(@a, 10, 5)
    Current.tenant = @b
    assert_nil WarehouseTier.where(shareId: nil).find_by(id: tier.id)
    assert_raises(ActiveRecord::RecordNotFound) { WarehouseTier.find(tier.id) }
  end

  test 'both tenants can hold the same default threshold independently' do
    tier_for(@a, 10, 5)
    tier_for(@b, 10, 20)
    assert_equal 5, Current.set(tenant: @a) { WarehouseTier.where(shareId: nil).sole.discountPercent.to_i }
    assert_equal 20, Current.set(tenant: @b) { WarehouseTier.where(shareId: nil).sole.discountPercent.to_i }
  end

  test 'a share uses only its own tenants default tiers without a tenant in context' do
    tier_for(@a, 10, 5)
    tier_for(@b, 10, 20)
    share_b = Current.set(tenant: @b) { WarehouseShare.create!(name: 'Vendor B', priceMultiplier: 1) }
    Current.tenant = nil
    assert_equal [20], WarehouseShare.unscoped.find(share_b.id).effective_tiers.map { |t| t.discountPercent.to_i }
    assert_equal 20.0, WarehouseShare.unscoped.find(share_b.id).discount_for(10)
  end
end
