# frozen_string_literal: true

class AddDemoReviewToTimesheets < ActiveRecord::Migration[8.1]
  def up
    add_column :timesheets, :demo, :boolean, default: false, null: false
    add_reference :timesheets, :assigned_reviewer
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Demo markers must be retained to keep fictional hours out of payroll.'
  end
end
