# frozen_string_literal: true

# Mirrored Shopify quantities are clamped to zero so downstream readers never
# see negative stock. Keep the platform's own number alongside so oversold
# (negative) stock is visible instead of silently erased. Null for rows that
# have no platform-reported figure (Square, local edits).
class AddSourceQuantityToInventoryLevels < ActiveRecord::Migration[8.1]
  def change
    add_column :InventoryLevel, :sourceQuantity, :integer
  end
end
