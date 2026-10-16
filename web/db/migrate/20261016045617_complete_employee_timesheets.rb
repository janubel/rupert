# frozen_string_literal: true
class CompleteEmployeeTimesheets < ActiveRecord::Migration[8.1]
  def change
    add_column :timesheets, :submitted_at, :datetime
    add_column :timesheets, :review_note, :text
    add_column :timesheet_entries, :notes, :text
    add_column :timesheet_entries, :clock_shift_id, :bigint
    add_index :timesheet_entries, [:tenant_id, :clock_shift_id, :worked_on], unique: true, name: 'idx_timesheet_shift_day'
    create_table :timesheet_events do |t|
      t.string :tenant_id, null: false
      t.bigint :timesheet_id, null: false
      t.bigint :user_id
      t.string :action, null: false
      t.text :details
      t.timestamps
      t.index [:tenant_id, :timesheet_id]
    end
    create_table :employee_app_sessions do |t|
      t.string :tenant_id, null: false
      t.bigint :user_id, null: false
      t.bigint :employee_id, null: false
      t.string :token_digest, null: false
      t.string :password_fingerprint, null: false
      t.string :device_name, null: false
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.timestamps
      t.index :token_digest, unique: true
      t.index [:tenant_id, :user_id]
    end
    create_table :employee_access_grants do |t|
      t.string :tenant_id, null: false
      t.bigint :user_id, null: false
      t.bigint :employee_id, null: false
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.timestamps
      t.index :token_digest, unique: true
    end
  end
end
