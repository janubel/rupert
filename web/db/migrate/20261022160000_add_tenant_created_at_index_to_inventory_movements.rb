# frozen_string_literal: true

class AddTenantCreatedAtIndexToInventoryMovements < ActiveRecord::Migration[8.1]
  def change
    add_index :InventoryMovement, %i[tenant_id createdAt],
      name: 'idx_inventory_movements_tenant_created_at'
    remove_index :InventoryMovement, :tenant_id, name: 'index_InventoryMovement_on_tenant_id'
  end
end
