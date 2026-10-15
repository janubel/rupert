# frozen_string_literal: true

class AddInventoryCountComparisonSnapshot < ActiveRecord::Migration[8.1]
  def change
    # No backfill: historical aggregate totals have no verified pool provenance.
    add_column :InventoryCountItem, :comparison_snapshot, :text
  end
end
