# frozen_string_literal: true

# Keep tenant-scoped SKU lookups on a compact composite SQLite index.
class AddLowerSkuIndexToOrderLines < ActiveRecord::Migration[8.1]
  def change
    add_index :order_lines, %i[tenant_id sku], name: 'idx_order_lines_tenant_sku_sqlite'
  end
end
