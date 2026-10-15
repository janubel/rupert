# frozen_string_literal: true

class CreateRemoteTimeClock < ActiveRecord::Migration[8.1]
  def change
    create_table :clock_shifts do |t|
      t.string :tenant_id, null: false
      t.references :user, foreign_key: { on_delete: :nullify }
      t.references :employee, foreign_key: { on_delete: :nullify }
      t.string :employee_key, null: false
      t.string :employee_name, null: false
      t.string :employment_type, null: false
      t.string :request_token, null: false
      t.datetime :started_at, null: false
      t.datetime :ended_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :clock_shifts, %i[tenant_id user_id], unique: true,
      where: 'ended_at IS NULL AND user_id IS NOT NULL', name: 'idx_clock_one_open_shift'
    add_index :clock_shifts, %i[tenant_id request_token], unique: true, name: 'idx_clock_shift_request'
    add_index :clock_shifts, %i[tenant_id started_at ended_at], name: 'idx_clock_shift_window'
    add_check_constraint :clock_shifts, 'ended_at IS NULL OR ended_at > started_at', name: 'clock_positive_interval'
    add_foreign_key :clock_shifts, :tenants

    create_table :clock_corrections do |t|
      t.string :tenant_id, null: false
      t.references :clock_shift, null: false, foreign_key: true
      t.references :requested_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :reviewed_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :original_started_at, null: false
      t.datetime :original_ended_at
      t.datetime :proposed_started_at, null: false
      t.datetime :proposed_ended_at, null: false
      t.text :reason, null: false
      t.string :status, null: false, default: 'pending'
      t.datetime :reviewed_at
      t.timestamps
    end
    add_index :clock_corrections, %i[tenant_id status created_at], name: 'idx_clock_correction_review'
    add_check_constraint :clock_corrections, 'proposed_ended_at > proposed_started_at', name: 'clock_correction_positive_interval'
    add_check_constraint :clock_corrections, "status IN ('pending', 'approved', 'rejected')", name: 'clock_correction_status'
    add_foreign_key :clock_corrections, :tenants
  end
end
