# frozen_string_literal: true

require 'test_helper'

# Structural guard: any table that carries a tenant column must be read through
# TenantScoped (default scope + attribution on create). New tables therefore
# cannot silently leak between workspaces. A model may opt out only by being
# listed here with the reason its rows are intentionally not scoped.
class TenantScopeGuardTest < ActiveSupport::TestCase
  UNSCOPED_ON_PURPOSE = {
    'Setting' => 'keyed by (key, tenant_id) explicitly; platform keys use a nil tenant',
    'RolePermission' => 'always queried with an explicit tenant_id (users/permissions controllers, User#effective_permissions)',
    'UserPermission' => 'reached through its owning User, which is tenant-checked',
    'CustomerSubscription' => 'control-plane billing and signed webhooks; customer controllers bind explicit tenant, platform requires super admin',
    'CustomerReferral' => 'cross-customer eligibility lookup; only own workspace can issue a code',
    'SupportAccessGrant' => 'cross-tenant authorization boundary; grants bind explicit tenant and named operator',
    'SupportAccessEvent' => 'platform audit; customer history is explicitly tenant-filtered',
    'WorkspaceSignup' => 'platform-owner review queue; rows exist before a tenant does',
    'WarehouseCart' => 'anonymous vendor carts resolved by token with the tenant taken from the share',
    'WarehouseCartItem' => 'belongs to a WarehouseCart; tenant set from the cart'
  }.freeze

  TENANT_COLUMNS = %w[tenant_id tenantId].freeze

  setup { Rails.application.eager_load! }

  def tenant_models
    ApplicationRecord.descendants.select do |model|
      next false if model.abstract_class? || model.name.nil? || model.name.start_with?('ActiveRecord::', 'ActiveStorage::')

      model.table_exists? && (model.column_names & TENANT_COLUMNS).any?
    end
  end

  test 'every model with a tenant column is tenant scoped or explicitly justified' do
    offenders = tenant_models.reject { |m| m.include?(TenantScoped) || UNSCOPED_ON_PURPOSE.key?(m.name) }
    assert_empty offenders.map(&:name).sort,
      'These models have a tenant column but do not include TenantScoped. Include it, or list the model in ' \
      'UNSCOPED_ON_PURPOSE with the reason.'
  end

  test 'the unscoped allowlist contains no stale entries' do
    names = tenant_models.map(&:name)
    stale = UNSCOPED_ON_PURPOSE.keys.reject { |n| names.include?(n) } +
      UNSCOPED_ON_PURPOSE.keys.select { |n| n.safe_constantize&.include?(TenantScoped) }
    assert_empty stale.uniq, 'Remove entries that no longer apply from UNSCOPED_ON_PURPOSE.'
  end

  test 'every scoped model filters its default query to the current tenant' do
    other = Tenant.create!(name: 'Guard Co', subdomain: "guard#{SecureRandom.hex(4)}")
    unfiltered = tenant_models.select { |m| m.include?(TenantScoped) }.reject do |model|
      Current.set(tenant: other) { model.all.to_sql.include?(other.id) }
    end
    assert_empty unfiltered.map(&:name)
  end
end
