# frozen_string_literal: true

# Serializes local catalog decisions with source auto-matching. The first
# transaction statement acquires SQLite's writer lock before either caller reads mapping ownership.
class CatalogMappingLock
  def self.synchronize
    tenant_id = Current.tenant_id
    raise ActiveRecord::RecordNotFound if tenant_id.blank?

    ApplicationRecord.transaction do
      locked = Tenant.unscoped.where(id: tenant_id, status: 'active').update_all(updated_at: Arel.sql('updated_at'))
      raise ActiveRecord::RecordNotFound unless locked == 1

      yield
    end
  end
end
