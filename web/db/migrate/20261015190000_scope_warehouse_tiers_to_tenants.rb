# frozen_string_literal: true

# WarehouseTier rows with a nil shareId were one global schedule shared by every
# workspace, so one tenant's edit changed every tenant's bulk discounts. Give
# each tier a tenant: share tiers inherit their share's tenant and each former
# global tier is copied to every existing tenant, then the shared rows are removed.
class ScopeWarehouseTiersToTenants < ActiveRecord::Migration[8.1]
  class MigrationTier < ActiveRecord::Base
    self.table_name = 'WarehouseTier'
    self.primary_key = 'id'
    self.inheritance_column = nil
  end

  class MigrationShare < ActiveRecord::Base
    self.table_name = 'WarehouseShare'
    self.primary_key = 'id'
  end

  class MigrationTenant < ActiveRecord::Base
    self.table_name = 'tenants'
  end

  def up
    add_column :WarehouseTier, :tenantId, :string
    add_index :WarehouseTier, :tenantId, name: 'index_WarehouseTier_on_tenantId'
    MigrationTier.reset_column_information

    MigrationShare.find_each do |share|
      MigrationTier.where(shareId: share.id).update_all(tenantId: share.tenantId)
    end

    globals = MigrationTier.where(shareId: nil, tenantId: nil).to_a
    MigrationTenant.find_each do |tenant|
      globals.each do |tier|
        MigrationTier.create!(
          id: SecureRandom.alphanumeric(25).downcase,
          tenantId: tenant.id, shareId: nil,
          minQty: tier.minQty, discountPercent: tier.discountPercent, createdAt: tier.createdAt
        )
      end
    end
    MigrationTier.where(id: globals.map(&:id)).delete_all

    add_foreign_key :WarehouseTier, :tenants, column: :tenantId
  end

  def down
    remove_foreign_key :WarehouseTier, column: :tenantId
    # Collapse per-tenant defaults back to one shared set (the first tenant's rows win).
    first = MigrationTier.where(shareId: nil).where.not(tenantId: nil).order(:createdAt, :id).pluck(:tenantId).first
    MigrationTier.where(shareId: nil).where.not(tenantId: first).delete_all if first
    remove_index :WarehouseTier, name: 'index_WarehouseTier_on_tenantId'
    remove_column :WarehouseTier, :tenantId
  end
end
