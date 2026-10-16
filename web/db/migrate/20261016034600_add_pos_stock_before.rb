# frozen_string_literal: true
class AddPosStockBefore < ActiveRecord::Migration[8.0]
  def change
    add_column :pos_stock_allocations, :source_quantity_before, :integer
  end
end
