# frozen_string_literal: true

# Timesheets surface a 1% sales commission and a fixed bonus for each employee
# 50%-off card redemption. Only the credited sales and redemption count are
# stored; commission and bonus are derived display figures and are not posted
# to payroll.
class AddCommissionAndCardBonusToTimesheets < ActiveRecord::Migration[8.1]
  def up
    add_column :timesheets, :sales_cents, :integer, default: 0, null: false
    add_column :timesheets, :card_redemptions, :integer, default: 0, null: false
  end

  def down
    remove_column :timesheets, :card_redemptions
    remove_column :timesheets, :sales_cents
  end
end
