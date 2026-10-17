# frozen_string_literal: true

# Planned (future) work shifts that managers enter and employees read. These
# are intentions, not hours worked: clock shifts and timesheets stay separate.
class CreateScheduledShifts < ActiveRecord::Migration[8.1]
  def change
    create_table :scheduled_shifts do |t|
      t.string :tenant_id, null: false
      t.references :employee, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false
      t.string :role_label
      t.text :notes
      t.timestamps
    end
    add_index :scheduled_shifts, %i[tenant_id starts_at], name: 'idx_scheduled_shift_window'
    add_index :scheduled_shifts, %i[employee_id starts_at], name: 'idx_scheduled_shift_employee'
    add_check_constraint :scheduled_shifts, 'ends_at > starts_at', name: 'scheduled_shift_positive_interval'
  end
end
